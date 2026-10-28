#!/usr/bin/env bash
# ┌──────────────────────────────────────────────────────────────────────────┐
# │  Mattermost Pre-Flight                                                   │
# │  Readiness checks for Mattermost components on RHEL 9 / 10               │
# └──────────────────────────────────────────────────────────────────────────┘
#
#  Full guide: README.md
#
#  Usage
#    sudo ./mm-preflight.sh                               interactive
#    sudo ./mm-preflight.sh -a site.conf                  answer file (asks for anything missing)
#    sudo ./mm-preflight.sh -a site.conf -y               unattended / CI
#    ./mm-preflight.sh --template app > site.conf         answer-file template
#    sudo ./mm-preflight.sh --listen tcp:8065,udp:8443    temporary listeners for peer tests
#    ./mm-preflight.sh --probe udp:rtcd1:8443             one-off probe from any machine
#
#  Exit codes   0 ready · 1 ready with warnings · 2 not ready · 64 usage · 130 interrupted
#
#  Uses only tools shipped with RHEL 9/10: bash, coreutils, util-linux, curl,
#  openssl, iproute (ss), glibc (getent), python3 (a dnf dependency).
#  Optional for deeper checks: postgresql (psql), openldap-clients (ldapsearch).

if [ -z "${BASH_VERSION:-}" ]; then echo "Mattermost Pre-Flight must be run with bash." >&2; exit 64; fi
if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4 ) )); then
  echo "Mattermost Pre-Flight needs bash 4.4 or newer (found ${BASH_VERSION})." >&2; exit 64
fi

set -o pipefail
set -u
shopt -s extglob
umask 077

readonly MMPF_VERSION="1.0.0"
readonly SELF="${0##*/}"
STAMP=$(date +%Y%m%d-%H%M%S)
HOST_SHORT=$(hostname -s 2>/dev/null || hostname)

# ── Documentation ────────────────────────────────────────────────────────────
readonly DOC_REQS="https://docs.mattermost.com/deployment-guide/software-hardware-requirements"
readonly DOC_NETWORK="https://docs.mattermost.com/deployment-guide/server/prepare-network"
readonly DOC_DB="https://docs.mattermost.com/deployment-guide/server/prepare-database"
readonly DOC_FILES="https://docs.mattermost.com/deployment-guide/server/prepare-file-storage"
readonly DOC_NGINX="https://docs.mattermost.com/deployment-guide/server/setup-nginx-proxy"
readonly DOC_TLS="https://docs.mattermost.com/deployment-guide/server/setup-tls"
readonly DOC_HA="https://docs.mattermost.com/deployment-guide/server/high-availability-cluster-based-deployment"
readonly DOC_RHEL="https://docs.mattermost.com/deployment-guide/server/linux/deploy-rhel.html"
readonly DOC_CALLS="https://docs.mattermost.com/deployment-guide/calls/calls-deployment-guide"
readonly DOC_RTCD="https://docs.mattermost.com/deployment-guide/calls/calls-rtcd-setup"
readonly DOC_OFFLOADER="https://docs.mattermost.com/deployment-guide/calls/calls-offloader-setup"
readonly DOC_SEARCH="https://docs.mattermost.com/deployment-guide/scale/enterprise-search"
readonly DOC_REDIS="https://docs.mattermost.com/deployment-guide/scale/redis"
readonly DOC_MOBILE="https://docs.mattermost.com/deployment-guide/mobile/mobile-app-deployment"
readonly DOC_AIRGAP="https://docs.mattermost.com/deployment-guide/air-gapped-operations"
readonly DOC_SCALE="https://docs.mattermost.com/deployment-guide/scale/scaling-for-enterprise"

# ── Mattermost reference architectures ─────────────────────────────────────
#  Source: docs.mattermost.com/deployment-guide/scale/scale-to-*-users (tested on AWS with
#  PostgreSQL, 100M posts, Mattermost v9.5 ESR). User counts are CONCURRENT users.
#  users | app nodes vCPU GiB | db writer vCPU GiB | db readers | search nodes vCPU GiB
REF_TIERS=(
  "200    1 2 4    2 16    0   0 0 0"
  "2000   2 2 4    2 16    1   2 4 32"
  "15000  2 4 8    4 32    1   2 4 32"
  "30000  2 8 16   8 64    1   4 8 64"
  "50000  5 8 16   8 64    4   4 8 64"
  "100000 6 16 32  16 128  5   4 8 64"
)
#  Single-server team guidance (registered users): 1-1,000 on 1 vCPU / 2 GB; 1,000-2,000 on 2 vCPU / 4 GB.
#  Every reference tier was tested with a 16 vCPU / 64 GiB proxy (noted by Mattermost as overspecified when small).

# ── Roles ────────────────────────────────────────────────────────────────────
ROLE_ORDER=(app db proxy rtcd offloader search pushproxy)
declare -A ROLE_NAME=(
  [app]="Mattermost application server"   [db]="PostgreSQL database server"
  [proxy]="Reverse proxy / load balancer" [rtcd]="Calls RTCD server"
  [offloader]="Calls offloader"           [search]="Elasticsearch / OpenSearch node"
  [pushproxy]="Self-hosted push proxy" )
declare -A ROLE_DESC=(
  [app]="Mattermost server binary, single node or cluster member"
  [db]="Primary or replica PostgreSQL"
  [proxy]="NGINX or load balancer in front of Mattermost"
  [rtcd]="Dedicated media server for Mattermost Calls"
  [offloader]="Call recording, transcription and live captions"
  [search]="Enterprise search cluster node"
  [pushproxy]="Relays mobile notifications to Apple and Google" )
# Sizing floors (warnings only). Override with MIN_CPU / MIN_RAM_GB / MIN_DISK_GB / DISK_PATH.
declare -A DEF_CPU=([app]=2 [db]=2 [proxy]=1 [rtcd]=2 [offloader]=4 [search]=2 [pushproxy]=1)
declare -A DEF_RAM=([app]=4 [db]=4 [proxy]=2 [rtcd]=4 [offloader]=8 [search]=8 [pushproxy]=1)
declare -A DEF_DISK=([app]=20 [db]=20 [proxy]=5 [rtcd]=5 [offloader]=20 [search]=20 [pushproxy]=5)
declare -A DEF_DISK_PATH=([app]=/opt [db]=/var [proxy]=/var/log [rtcd]=/opt
                          [offloader]=/var/lib/docker [search]=/var/lib [pushproxy]=/opt)

# ── Options ──────────────────────────────────────────────────────────────────
OPT_ANSWERS="" OPT_ROLE="" OPT_YES=0 OPT_NO_COLOR=0 OPT_ASCII=0 OPT_TIMEOUT=5
OPT_REPORT_DIR="" OPT_SAVE="" OPT_LISTEN="" OPT_DURATION=900 OPT_PROBE="" OPT_TEMPLATE=""

usage() {
  cat <<EOF
Mattermost Pre-Flight v$MMPF_VERSION
Checks that this RHEL 9/10 server is ready for a Mattermost component install.

Usage: $SELF [options]

  -a, --answers FILE       Read answers from FILE (KEY=value lines)
  -r, --role ROLE          app | db | proxy | rtcd | offloader | search | pushproxy
  -y, --non-interactive    Never prompt; use the answer file and defaults only
      --save-answers FILE  Save answers (secrets excluded) to FILE after the run
      --report-dir DIR     Where to write the report (default: current directory)
      --timeout SECONDS    Network timeout per check (default: 5)
      --template ROLE      Print an answer-file template (a role or 'all') and exit
      --listen SPECS       Open temporary listeners, e.g. tcp:8065,udp:8443,perf:18999
                           (perf = bandwidth test endpoint for peers)
      --duration SECONDS   How long --listen stays up (default: 900)
      --probe SPECS        Probe from this machine: tcp|udp|rtt|perf:HOST:PORT
                           e.g. tcp:db1:5432,rtt:db1:5432,udp:rtcd1:8443,perf:app2:18999
      --no-color           Plain output (NO_COLOR is honoured too)
      --ascii              ASCII symbols only
  -h, --help               Show this help
  -V, --version            Show version

Exit codes: 0 ready · 1 ready with warnings · 2 not ready · 64 usage error · 130 interrupted
EOF
}

die()  { printf '%s: %s\n' "$SELF" "$*" >&2; exit 64; }
need() { [[ $# -ge 2 && -n $2 ]] || die "option $1 needs a value (see --help)"; }

parse_args() {
  while (($#)); do
    case $1 in
      -a|--answers)        need "$@"; OPT_ANSWERS=$2; shift 2 ;;
      -r|--role)           need "$@"; OPT_ROLE=$2; shift 2 ;;
      -y|--non-interactive) OPT_YES=1; shift ;;
      --save-answers)      need "$@"; OPT_SAVE=$2; shift 2 ;;
      --report-dir)        need "$@"; OPT_REPORT_DIR=$2; shift 2 ;;
      --timeout)           need "$@"; OPT_TIMEOUT=$2; shift 2 ;;
      --template)          need "$@"; OPT_TEMPLATE=$2; shift 2 ;;
      --listen)            need "$@"; OPT_LISTEN=$2; shift 2 ;;
      --duration)          need "$@"; OPT_DURATION=$2; shift 2 ;;
      --probe)             need "$@"; OPT_PROBE=$2; shift 2 ;;
      --no-color)          OPT_NO_COLOR=1; shift ;;
      --ascii)             OPT_ASCII=1; shift ;;
      -h|--help)           usage; exit 0 ;;
      -V|--version)        echo "Mattermost Pre-Flight $MMPF_VERSION"; exit 0 ;;
      *)                   die "unknown option: $1 (see --help)" ;;
    esac
  done
  [[ $OPT_TIMEOUT =~ ^[0-9]+$ ]] && (( OPT_TIMEOUT > 0 )) || die "--timeout must be a positive number"
  [[ $OPT_DURATION =~ ^[0-9]+$ ]] || die "--duration must be a number of seconds"
  if [[ -n $OPT_ROLE && -z ${ROLE_NAME[$OPT_ROLE]:-} ]]; then die "unknown role '$OPT_ROLE' (app, db, proxy, rtcd, offloader, search, pushproxy)"; fi
  if [[ -n $OPT_ANSWERS && ! -r $OPT_ANSWERS ]]; then die "cannot read answer file: $OPT_ANSWERS"; fi
}

# ════════════════════════════════════════════════════════════════════════════
#  UI
# ════════════════════════════════════════════════════════════════════════════
setup_ui() {
  IS_TTY=0; [[ -t 1 ]] && IS_TTY=1
  local cs="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  USE_UNICODE=1; [[ $cs =~ [Uu][Tt][Ff]-?8 ]] || USE_UNICODE=0; ((OPT_ASCII)) && USE_UNICODE=0
  USE_COLOR=$IS_TTY; [[ -n ${NO_COLOR:-} ]] && USE_COLOR=0; ((OPT_NO_COLOR)) && USE_COLOR=0

  local cols; cols=$( (tput cols) 2>/dev/null ) || cols=80; [[ $cols =~ ^[0-9]+$ ]] || cols=80
  W=$(( cols - 2 )); (( W > 96 )) && W=96; (( W < 64 )) && W=64

  BLUE="" YELLOW="" GREEN="" RED="" GRAY="" WHITE="" BG_BLUE="" BOLD="" UL="" RESET=""
  if ((USE_COLOR)); then
    if [[ ${COLORTERM:-} =~ ^(truecolor|24bit)$ ]]; then
      BLUE=$'\e[38;2;28;88;217m'   YELLOW=$'\e[38;2;255;188;31m' GREEN=$'\e[38;2;61;184;135m'
      RED=$'\e[38;2;210;75;78m'    GRAY=$'\e[38;2;139;148;158m'  WHITE=$'\e[38;2;255;255;255m'
      BG_BLUE=$'\e[48;2;28;88;217m'
    else
      BLUE=$'\e[38;5;26m' YELLOW=$'\e[38;5;214m' GREEN=$'\e[38;5;36m' RED=$'\e[38;5;167m'
      GRAY=$'\e[38;5;245m' WHITE=$'\e[38;5;231m' BG_BLUE=$'\e[48;5;26m'
    fi
    BOLD=$'\e[1m' UL=$'\e[4m' RESET=$'\e[0m'
  fi
  if ((USE_UNICODE)); then
    G_PASS="✔" G_FAIL="✖" G_WARN="▲" G_SKIP="○" G_INFO="•" G_ARROW="→" G_LINK="↗" G_DOT="·"
    G_FULL="━" G_EMPTY="─" G_RULE="─" G_ACCENT="▍" G_Q="?" G_PROMPT="›" G_LOGO="◆"
    B_TL="╭" B_TR="╮" B_BL="╰" B_BR="╯" B_V="│" B_H="─"
    SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  else
    G_PASS="+" G_FAIL="x" G_WARN="!" G_SKIP="-" G_INFO="i" G_ARROW="->" G_LINK="=>" G_DOT="-"
    G_FULL="#" G_EMPTY="." G_RULE="-" G_ACCENT="|" G_Q="?" G_PROMPT=">" G_LOGO="*"
    B_TL="+" B_TR="+" B_BL="+" B_BR="+" B_V="|" B_H="-"
    SPIN=('|' '/' '-' '\')
  fi
}

# ASCII fallback for terminals without UTF-8
ax() {
  local s=$1
  if ((USE_UNICODE)); then printf '%s' "$s"; return; fi
  s=${s//→/->}; s=${s//·/-}; s=${s//—/-}; s=${s//…/...}; s=${s//≥/>=}; s=${s//×/x}; s=${s//•/*}
  printf '%s' "$s"
}
rep()     { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }
vislen()  { local s=${1//$'\e'\[*([0-9;])m/}; printf '%s' "${#s}"; }
trunc()   { local s=$1 n=$2; if (( ${#s} > n )); then if ((USE_UNICODE)); then printf '%s…' "${s:0:n-1}"; else printf '%s...' "${s:0:n-3}"; fi; else printf '%s' "$s"; fi; }
oneline() { local s; s=$(printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//'); trunc "$s" "${2:-140}"; }
have()    { command -v "$1" >/dev/null 2>&1; }
now_ms()  { if [[ -n ${EPOCHREALTIME:-} ]]; then local t=${EPOCHREALTIME/[.,]/}; echo $(( t / 1000 )); else echo $(( $(date +%s%N) / 1000000 )); fi; }
cursor()  { ((IS_TTY)) || return 0; if [[ $1 == hide ]]; then printf '\e[?25l'; else printf '\e[?25h'; fi; }

banner() {
  if ((!USE_COLOR)); then
    printf '\n  %s  Mattermost Pre-Flight  v%s\n  %s\n  Readiness checks for Mattermost on RHEL 9 / 10\n' "$G_LOGO" "$MMPF_VERSION" "$(rep "$G_RULE" $((W - 2)))"
    return
  fi
  local title=" ${G_LOGO}   Mattermost Pre-Flight" ver="v${MMPF_VERSION}  " inner=$((W - 2)) gap
  gap=$(( inner - ${#title} - ${#ver} )); (( gap < 1 )) && gap=1
  printf '\n'
  printf '  %s%*s%s\n' "$BG_BLUE" "$inner" '' "$RESET"
  printf '  %s%s%s %s%s%s%s%*s%s%s%s\n' "$BG_BLUE" "$YELLOW$BOLD" " ${G_LOGO} " "$RESET$BG_BLUE$WHITE$BOLD" \
         " Mattermost Pre-Flight" "$RESET" "$BG_BLUE" "$gap" '' "$YELLOW" "$ver" "$RESET"
  printf '  %s%*s%s\n' "$BG_BLUE" "$inner" '' "$RESET"
  printf '  %sReadiness checks for Mattermost on RHEL 9 / 10%s\n' "$GRAY" "$RESET"
}

mode_header() {
  set -- "$(ax "$1")"
  printf '\n\n  %s%s%s\n  %s%s%s\n' "$BOLD" "$1" "$RESET" "$GRAY" "$(rep "$G_RULE" $((W - 2)))" "$RESET"
}

step_header() {
  set -- "$1" "$2" "$(ax "$3")"
  printf '\n\n  %sSTEP %s OF %s%s\n  %s%s%s\n  %s%s%s\n' "$YELLOW$BOLD" "$1" "$2" "$RESET" \
         "$BOLD" "$3" "$RESET" "$GRAY" "$(rep "$G_RULE" $((W - 2)))" "$RESET"
}

section_header() {
  local title n=$2 right gap; title=$(ax "$1")
  right="$n check$([[ $n == 1 ]] || echo s)"
  gap=$(( W - 6 - ${#title} - ${#right} )); (( gap < 2 )) && gap=2
  printf '\n  %s%s%s %s%s%s%*s%s%s%s\n' "$YELLOW" "$G_ACCENT" "$RESET" "$BOLD" "$title" "$RESET" \
         "$gap" '' "$GRAY" "$right" "$RESET"
}

progress_bar() {
  local cur=$1 tot=$2 width=22 filled
  (( tot < 1 )) && tot=1
  filled=$(( cur * width / tot ))
  printf '%s%s%s%s%s %s%d/%d%s' "$BLUE" "$(rep "$G_FULL" "$filled")" "$GRAY" \
         "$(rep "$G_EMPTY" $((width - filled)))" "$RESET" "$GRAY" "$cur" "$tot" "$RESET"
}

SPIN_PID=""
spinner_start() {
  ((IS_TTY)) || return 0
  local label bar lw=$(( W - 36 ))
  label=$(trunc "$(ax "$1")" "$lw"); bar=$(progress_bar "$2" "$3")
  local pad=$(( lw - ${#label} )); (( pad < 0 )) && pad=0
  (
    trap - EXIT INT; trap 'exit 0' TERM
    local i=0 n=${#SPIN[@]}
    while :; do
      printf '\r\e[2K  %s%s%s  %s%*s  %s' "$BLUE" "${SPIN[i % n]}" "$RESET" "$label" "$pad" '' "$bar"
      i=$((i + 1)); sleep 0.08
    done
  ) 2>/dev/null &
  SPIN_PID=$!
  disown "$SPIN_PID" 2>/dev/null
}
spinner_stop() {
  [[ -n $SPIN_PID ]] || return 0
  kill "$SPIN_PID" 2>/dev/null
  local i; for i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$SPIN_PID" 2>/dev/null || break; sleep 0.01; done
  SPIN_PID=""; printf '\r\e[2K'
}

# Print wrapped, indented text: wrap_print <indent> <colour> <prefix> <text>
wrap_print() {
  local indent=$1 colour=$2 prefix=$3 text=$4 first=1 line
  local width=$(( W - indent - ${#prefix} - 1 ))
  while IFS= read -r line; do
    if ((first)); then printf '%*s%s%s %s%s\n' "$indent" '' "$colour" "$prefix" "$line" "$RESET"; first=0
    else printf '%*s%s%*s %s%s\n' "$indent" '' "$colour" "${#prefix}" '' "$line" "$RESET"; fi
  done <<< "$(printf '%s\n' "$text" | fold -s -w "$width" | sed 's/ *$//')"
}

LBL_W=30
render_result() {
  local st=$1 label=$2 detail=$3 fix=$4 doc=$5 g c dc
  case $st in
    PASS) g=$G_PASS c=$GREEN  dc=$GRAY ;;
    WARN) g=$G_WARN c=$YELLOW dc=$YELLOW ;;
    FAIL) g=$G_FAIL c=$RED    dc=$RED ;;
    SKIP) g=$G_SKIP c=$GRAY   dc=$GRAY ;;
    *)    g=$G_INFO c=$BLUE   dc=$GRAY ;;
  esac
  label=$(trunc "$(ax "$label")" "$LBL_W")
  detail=$(ax "$detail"); fix=$(ax "$fix")
  local dw=$(( W - LBL_W - 7 )) lb="" first=1 line
  (( dw < 20 )) && dw=20
  [[ $st == FAIL ]] && lb=$BOLD
  [[ -z $detail ]] && detail=" "
  while IFS= read -r line; do
    if ((first)); then
      printf '  %s%s%s  %s%s%s%*s  %s%s%s\n' "$c" "$g" "$RESET" "$lb" "$label" "$RESET" \
             $(( LBL_W - ${#label} )) '' "$dc" "$line" "$RESET"; first=0
    else
      printf '  %*s  %s%s%s\n' $(( LBL_W + 3 )) '' "$dc" "$line" "$RESET"
    fi
  done <<< "$(printf '%s\n' "$detail" | fold -s -w "$dw" | sed 's/ *$//')"
  if [[ $st == FAIL || $st == WARN ]] && [[ -n $fix ]]; then wrap_print 5 "$GRAY" "$G_ARROW" "$fix"; fi
  if [[ $st != PASS && -n $doc ]]; then printf '     %s%s %s%s%s\n' "$BLUE" "$G_LINK" "$UL" "$doc" "$RESET"; fi
}

box() {
  local inner=$((W - 6)) l vl
  local -a lines=(); for l in "$@"; do lines+=("$(ax "$l")"); done; set -- "${lines[@]}"
  printf '  %s%s%s%s%s\n' "$GRAY" "$B_TL" "$(rep "$B_H" $((inner + 2)))" "$B_TR" "$RESET"
  for l in "$@"; do
    vl=$(vislen "$l"); (( vl > inner )) && vl=$inner
    printf '  %s%s%s %s%*s %s%s%s\n' "$GRAY" "$B_V" "$RESET" "$l" $((inner - vl)) '' "$GRAY" "$B_V" "$RESET"
  done
  printf '  %s%s%s%s%s\n' "$GRAY" "$B_BL" "$(rep "$B_H" $((inner + 2)))" "$B_BR" "$RESET"
}

note()  { printf '  %s%s%s\n' "$GRAY" "$(ax "$*")" "$RESET"; }

# ════════════════════════════════════════════════════════════════════════════
#  Answers
# ════════════════════════════════════════════════════════════════════════════
declare -A ANS=()
ANS_ORDER=()
PENDING_GROUP=""
SECRET_KEYS="DB_PASSWORD S3_SECRET_KEY LDAP_BIND_PASSWORD SEARCH_PASSWORD"

get() { printf '%s' "${ANS[$1]:-${2:-}}"; }
is_yes() { [[ ${1,,} =~ ^(y|yes|true|1|on)$ ]]; }
is_secret() { [[ " $SECRET_KEYS " == *" $1 "* ]]; }

load_answers() {
  local line k v n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1)); line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    line=${line#*([[:space:]])export+([[:space:]])}
    if [[ $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      k=${BASH_REMATCH[1]^^}; v=${BASH_REMATCH[2]}
      v=${v##+([[:space:]])}
      [[ $v == '#'* ]] && v=""
      if [[ $v =~ ^\"([^\"]*)\" || $v =~ ^\'([^\']*)\' ]]; then
        v=${BASH_REMATCH[1]}                                    # quoted: taken literally
      else
        v=${v%%+([[:space:]])#*}; v=${v%%+([[:space:]])}         # strip " # comment"
      fi
      ANS[$k]=$v
    else
      printf '  %s%s%s Ignoring line %d of %s (expected KEY=value)\n' "$YELLOW" "$G_WARN" "$RESET" "$n" "$OPT_ANSWERS" >&2
    fi
  done < "$OPT_ANSWERS"
  local perms; perms=$(stat -c '%a' "$OPT_ANSWERS" 2>/dev/null || echo 600)
  for k in $SECRET_KEYS; do
    if [[ -n ${ANS[$k]:-} && $perms != 600 && $perms != 400 ]]; then
      printf '  %s%s%s %s contains secrets but is mode %s %s chmod 600 %s\n' "$YELLOW" "$G_WARN" "$RESET" \
             "$OPT_ANSWERS" "$perms" "$G_ARROW" "$OPT_ANSWERS" >&2
      break
    fi
  done
}

VALIDATE_MSG=""
validate() {
  local rule=$1 v=$2 opt=0
  [[ $rule == *'?' ]] && { opt=1; rule=${rule%'?'}; }
  if [[ -z $v ]]; then
    if ((opt)) || [[ $rule == any ]]; then return 0; fi
    VALIDATE_MSG="A value is required."; return 1
  fi
  case $rule in
    any) return 0 ;;
    port) [[ $v =~ ^[0-9]+$ ]] && (( v >= 1 && v <= 65535 )) && return 0
          VALIDATE_MSG="Enter a port number between 1 and 65535." ;;
    int)  [[ $v =~ ^[0-9]+$ ]] && return 0; VALIDATE_MSG="Enter a whole number." ;;
    num)  [[ $v =~ ^[0-9]+(\.[0-9]+)?$ ]] && return 0; VALIDATE_MSG="Enter a number." ;;
    host) [[ $v =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] && return 0
          VALIDATE_MSG="Enter a hostname or IPv4 address (no scheme or port)." ;;
    hostport) [[ $v =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] && return 0
          VALIDATE_MSG="Enter host or host:port." ;;
    hosts) local -a a; local x; IFS=', ' read -r -a a <<< "$v"
          for x in "${a[@]}"; do
            [[ -z $x || $x =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] && continue
            VALIDATE_MSG="'$x' isn't a valid host or host:port."; return 1
          done; return 0 ;;
    url)  [[ $v =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]] && return 0
          VALIDATE_MSG="Enter a full URL, e.g. https://chat.example.com" ;;
    ident) [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && return 0
          VALIDATE_MSG="Use letters, digits and underscores only." ;;
    user) [[ $v =~ ^[a-z_][a-z0-9_-]*$ ]] && return 0
          VALIDATE_MSG="Use a valid Linux user name (lowercase, digits, - and _)." ;;
    path) [[ $v == /* ]] && return 0; VALIDATE_MSG="Enter an absolute path." ;;
    yesno) [[ ${v,,} =~ ^(y|yes|n|no|true|false)$ ]] && return 0; VALIDATE_MSG="Answer yes or no." ;;
    choice:*) local c=" ${rule#choice:} "; c=${c//|/ }; [[ $c == *" $v "* ]] && return 0
          VALIDATE_MSG="Choose one of:${c// / · }" ; VALIDATE_MSG=${VALIDATE_MSG/: · /: }; VALIDATE_MSG=${VALIDATE_MSG% · } ;;
    *) return 0 ;;
  esac
  return 1
}

# Optional overrides that are never asked for. They reach (( )) and awk, so reject anything that isn't the expected shape.
TUNING_KEYS="MIN_CPU:int MIN_RAM_GB:int MIN_DISK_GB:int DISK_PATH:path SSH_PORT:port PERF_MB:int BANDWIDTH_WARN_MBPS:int LATENCY_WARN_MS:num LATENCY_FAIL_MS:num"
check_tuning() {
  local kr k rule
  for kr in $TUNING_KEYS; do
    k=${kr%%:*} rule=${kr#*:}
    [[ -n ${ANS[$k]:-} ]] || continue
    validate "$rule" "${ANS[$k]}" || die "answer file: $k='${ANS[$k]}': $VALIDATE_MSG"
    ANS_ORDER+=("$k")
  done
}

group() { PENDING_GROUP=$1; }

# ask KEY "Question" "default" "hint" rule [secret]
ask() {
  local key=$1 q=$2 def=${3:-} hint=${4:-} rule=${5:-any} secret=${6:-0} a
  if [[ -v ANS[$key] ]]; then
    if validate "$rule" "${ANS[$key]}"; then
      [[ $rule == yesno* && -n ${ANS[$key]} ]] && { is_yes "${ANS[$key]}" && ANS[$key]=yes || ANS[$key]=no; }
      ANS_ORDER+=("$key"); return 0
    fi
    if ((!INTERACTIVE)); then die "answer file: $key='${ANS[$key]}': $VALIDATE_MSG"; fi
    printf '\n  %s%s%s Answer file value for %s is invalid: %s\n' "$RED" "$G_FAIL" "$RESET" "$key" "$VALIDATE_MSG"
    unset "ANS[$key]"
  fi
  if ((!INTERACTIVE)); then
    if ! validate "$rule" "$def"; then die "answer file is missing $key ($q)"; fi
    ANS[$key]=$def; ANS_ORDER+=("$key"); return 0
  fi
  if [[ -n $PENDING_GROUP ]]; then
    printf '\n  %s%s%s\n' "$BLUE$BOLD" "$PENDING_GROUP" "$RESET"; PENDING_GROUP=""
  fi
  while :; do
    printf '\n  %s%s%s %s' "$YELLOW" "$G_Q" "$RESET" "$q"
    [[ -n $def ]] && printf '  %s[%s]%s' "$GRAY" "$def" "$RESET"
    printf '\n'
    [[ -n $hint ]] && printf '    %s%s%s\n' "$GRAY" "$(ax "$hint")" "$RESET"
    printf '  %s%s%s ' "$BLUE" "$G_PROMPT" "$RESET"
    if ((secret)); then
      IFS= read -r -s a < /dev/tty || a=""; [[ -n $a ]] && printf '%s' '••••••••'; printf '\n'
    else
      IFS= read -r a < /dev/tty || a=""
    fi
    a=${a##+([[:space:]])}; a=${a%%+([[:space:]])}
    [[ -z $a ]] && a=$def
    if validate "$rule" "$a"; then
      [[ $rule == yesno* && -n $a ]] && { is_yes "$a" && a=yes || a=no; }
      ANS[$key]=$a; ANS_ORDER+=("$key"); return 0
    fi
    printf '    %s%s %s%s\n' "$RED" "$G_FAIL" "$VALIDATE_MSG" "$RESET"
  done
}

choose_role() {
  if [[ -n ${ANS[ROLE]:-} ]]; then
    [[ -n ${ROLE_NAME[${ANS[ROLE]}]:-} ]] || die "ROLE='${ANS[ROLE]}' is not a valid role"
    ROLE=${ANS[ROLE]}
    printf '  %s%s%s  %s%s%s  %s(from %s)%s\n' "$GREEN" "$G_PASS" "$RESET" "$BOLD" "${ROLE_NAME[$ROLE]}" "$RESET" \
           "$GRAY" "$([[ -n $OPT_ROLE ]] && echo "--role" || echo "answer file")" "$RESET"
    ANS_ORDER+=(ROLE); return
  fi
  ((INTERACTIVE)) || die "no role given. Use --role, or set ROLE= in the answer file"
  local i=1 r
  printf '\n'
  for r in "${ROLE_ORDER[@]}"; do
    printf '    %s%d%s  %-34s %s%s%s\n' "$BLUE$BOLD" "$i" "$RESET" "${ROLE_NAME[$r]}" "$GRAY" "$(ax "${ROLE_DESC[$r]}")" "$RESET"
    i=$((i + 1))
  done
  local a
  while :; do
    printf '\n  %s%s%s Which component will run on this server?  %s[1-%d]%s\n  %s%s%s ' \
           "$YELLOW" "$G_Q" "$RESET" "$GRAY" "${#ROLE_ORDER[@]}" "$RESET" "$BLUE" "$G_PROMPT" "$RESET"
    IFS= read -r a < /dev/tty || a=""
    if [[ $a =~ ^[0-9]+$ ]] && (( a >= 1 && a <= ${#ROLE_ORDER[@]} )); then ROLE=${ROLE_ORDER[a-1]}; break; fi
    if [[ -n ${ROLE_NAME[$a]:-} ]]; then ROLE=$a; break; fi
    printf '    %s%s Enter a number from the list.%s\n' "$RED" "$G_FAIL" "$RESET"
  done
  ANS[ROLE]=$ROLE; ANS_ORDER+=(ROLE)
  printf '  %s%s%s  %s%s%s\n' "$GREEN" "$G_PASS" "$RESET" "$BOLD" "${ROLE_NAME[$ROLE]}" "$RESET"
}

# ── Interviews ───────────────────────────────────────────────────────────────
interview_perf() {
  group "Capacity & network performance"
  case $ROLE in
    app|db|search)
      ask TARGET_USERS "Expected peak concurrent users (optional)" "" "Compared with Mattermost's published reference architectures" "int?" ;;
  esac
  ask PERF_TEST "Measure bandwidth to the other servers?" "no" "Each peer must be running:  sudo ./$SELF --listen perf:$(get PERF_PORT 18999)" yesno
  is_yes "$(get PERF_TEST)" && ask PERF_PORT "Bandwidth test port" "18999" "" port
  return 0
}

interview_network() {
  group "Internet access"
  ask AIR_GAPPED "Is this environment air-gapped (no internet)?" "no" "" yesno
  if ! is_yes "$(get AIR_GAPPED)"; then
    ask OUTBOUND_PROXY "Outbound HTTP proxy" "" "Blank for direct internet access, e.g. http://proxy.internal:3128" "url?"
    if [[ -n $(get OUTBOUND_PROXY) ]]; then
      ask NO_PROXY_LIST "Hosts that bypass the proxy (NO_PROXY)" "localhost,127.0.0.1" \
          "Comma-separated hosts or .domains. Include every internal service" any
    fi
  fi
}

interview_app() {
  group "Site"
  ask SITE_URL "Site URL users will open" "" "e.g. https://chat.example.com" "url?"
  ask APP_PEERS "Other app nodes in this cluster" "" "Comma separated hostnames; blank for a single server" "hosts?"

  group "Database"
  ask DB_HOST "PostgreSQL host" "" "Hostname or IP of the primary (or PgBouncer)" host
  ask DB_PORT "PostgreSQL port" "5432" "" port
  ask DB_NAME "Database name" "mattermost" "" ident
  ask DB_USER "Database user" "mmuser" "" ident
  ask DB_SSLMODE "SSL mode" "prefer" "disable · prefer · require · verify-ca · verify-full" "choice:disable|prefer|require|verify-ca|verify-full"
  ask DB_PASSWORD "Database password (optional)" "" "Used only for a live login test with psql. Never written to disk." "any" 1
  ask DB_REPLICAS "Read replicas" "" "Comma separated host[:port]; blank if none" "hosts?"

  group "File storage"
  ask FILE_STORE "Where will files be stored?" "local" "local · nfs · s3 (includes MinIO and other S3-compatible stores)" "choice:local|nfs|s3"
  case $(get FILE_STORE) in
    local|nfs) ask DATA_DIR "Data directory" "/opt/mattermost/data" "" path ;;
    s3)
      ask S3_ENDPOINT "S3 endpoint URL" "https://s3.amazonaws.com" "e.g. https://s3.eu-west-2.amazonaws.com or https://minio.internal:9000" url
      ask S3_BUCKET "Bucket name" "" "" req
      ask S3_REGION "Region" "us-east-1" "" any
      ask S3_PATH_STYLE "Use path-style URLs?" "no" "Answer yes for MinIO and most on-prem stores" yesno
      ask S3_ACCESS_KEY "Access key ID" "" "Blank to skip the write test (e.g. when using an IAM role)" any
      [[ -n $(get S3_ACCESS_KEY) ]] && ask S3_SECRET_KEY "Secret access key" "" "Never written to disk" req 1 ;;
  esac

  group "Email"
  ask SMTP_HOST "SMTP server" "" "Blank to skip email checks" "host?"
  if [[ -n $(get SMTP_HOST) ]]; then
    ask SMTP_SECURITY "SMTP connection security" "starttls" "starttls (usually port 587) · tls (465) · none (25)" "choice:starttls|tls|none"
    local dp=587; [[ $(get SMTP_SECURITY) == tls ]] && dp=465; [[ $(get SMTP_SECURITY) == none ]] && dp=25
    ask SMTP_PORT "SMTP port" "$dp" "" port
  fi

  group "Directory & single sign-on"
  ask LDAP_HOST "LDAP / Active Directory server" "" "Blank to skip" "host?"
  if [[ -n $(get LDAP_HOST) ]]; then
    ask LDAP_SECURITY "LDAP connection security" "ldaps" "ldaps · starttls · none" "choice:ldaps|starttls|none"
    local lp=389; [[ $(get LDAP_SECURITY) == ldaps ]] && lp=636
    ask LDAP_PORT "LDAP port" "$lp" "" port
    ask LDAP_BIND_DN "Bind DN (optional)" "" "e.g. CN=svc-mattermost,OU=Service,DC=corp,DC=example. Enables a bind test" any
    if [[ -n $(get LDAP_BIND_DN) ]]; then
      ask LDAP_BIND_PASSWORD "Bind password" "" "Never written to disk" any 1
      ask LDAP_BASE_DN "Base DN" "" "e.g. DC=corp,DC=example" any
    fi
  fi
  ask SSO_METADATA_URL "SAML / OpenID metadata URL" "" "Blank to skip" "url?"

  group "Search & cache"
  ask SEARCH_URL "Elasticsearch / OpenSearch URL" "" "e.g. https://search.internal:9200. Leave blank to skip" "url?"
  if [[ -n $(get SEARCH_URL) ]]; then
    ask SEARCH_USER "Search username (optional)" "" "" any
    [[ -n $(get SEARCH_USER) ]] && ask SEARCH_PASSWORD "Search password" "" "Never written to disk" any 1
  fi
  ask REDIS_HOST "Redis host[:port]" "" "Blank to skip" "hostport?"

  group "Calls"
  ask CALLS_MODE "How will Calls run?" "integrated" "integrated (plugin on this server) · rtcd (dedicated servers) · none" "choice:integrated|rtcd|none"
  case $(get CALLS_MODE) in
    integrated)
      ask RTC_PORT "Calls media port" "8443" "UDP and TCP" port
      ask ICE_HOST_OVERRIDE "ICE host override (optional)" "" "Public IP or hostname clients use to reach this server, if behind NAT" "host?" ;;
    rtcd)
      ask RTCD_HOSTS "RTCD servers" "" "Comma separated host[:api-port], API port defaults to 8045" hosts ;;
  esac
  if [[ $(get CALLS_MODE) != none ]]; then
    ask OFFLOADER_URL "Calls offloader URL (optional)" "" "e.g. http://offloader.internal:4545, used for recording and transcription" "url?"
  fi

  interview_network
  if [[ $(get CALLS_MODE) == integrated ]] && ! is_yes "$(get AIR_GAPPED)"; then
    ask STUN_SERVER "STUN server for public IP discovery" "stun.global.calls.mattermost.com:3478" "Blank to skip" "hostport?"
  fi

  group "Mobile push"
  local pd="https://push.mattermost.com"; is_yes "$(get AIR_GAPPED)" && pd=""
  ask PUSH_SERVER "Push notification server" "$pd" "push.mattermost.com (US) · hpns-de.mattermost.com (EU) · your push proxy · blank to skip" "url?"
}

interview_db() {
  group "PostgreSQL"
  ask DB_PORT "PostgreSQL port" "5432" "" port
  ask PG_MIN_VERSION "Minimum PostgreSQL major version" "15" "Mattermost v12.0+ requires 15; v11.7 ESR requires 14" int
  ask DB_NAME "Mattermost database name" "mattermost" "" ident
  ask DB_USER "Mattermost database user" "mmuser" "" ident
  group "Clients & peers"
  ask APP_NODES "Mattermost app servers that will connect" "" "Comma-separated. Used to check pg_hba.conf" "hosts?"
  ask MAX_OPEN_CONNS "SqlSettings.MaxOpenConns per app node" "300" "Used to size max_connections" int
  ask DB_PEERS "Replication peers (other DB nodes)" "" "Comma separated host[:port]; blank if standalone" "hosts?"
}

interview_proxy() {
  group "Site"
  ask SITE_URL "Site URL users will open" "" "e.g. https://chat.example.com" url
  ask APP_NODES "Upstream Mattermost app servers" "" "Comma separated host[:port], port defaults to 8065" hosts
  group "TLS certificate (optional)"
  ask TLS_CERT "Certificate file (PEM, full chain)" "" "e.g. /etc/pki/tls/certs/chat.example.com.pem. Leave blank to skip" "path?"
  [[ -n $(get TLS_CERT) ]] && ask TLS_KEY "Private key file" "" "Blank to skip the key match test" "path?"
}

interview_rtcd() {
  group "Calls RTCD"
  ask RTC_PORT "Calls media port" "8443" "UDP and TCP" port
  ask RTCD_API_PORT "RTCD API port" "8045" "Mattermost app nodes connect here" port
  ask ICE_HOST_OVERRIDE "ICE host override (optional)" "" "Public IP or hostname clients use to reach this server, if behind NAT" "host?"
  ask AIR_GAPPED "Is this environment air-gapped (no internet)?" "no" "" yesno
  if ! is_yes "$(get AIR_GAPPED)"; then
    ask STUN_SERVER "STUN server for public IP discovery" "stun.global.calls.mattermost.com:3478" "Blank to skip" "hostport?"
  fi
}

interview_offloader() {
  group "Calls offloader"
  ask SITE_URL "Mattermost site URL" "" "Recording jobs join calls through this URL" url
  ask RTC_TARGET "Calls media endpoint (host[:port])" "" "The RTCD server, or the app server if Calls is integrated. Port defaults to 8443" hostport
  ask OFFLOADER_PORT "Offloader API port" "4545" "" port
  ask OFFLOADER_USER "Service user" "calls-offloader" "" user
  interview_network
}

interview_search() {
  group "Search node"
  ask SEARCH_PORT "HTTP port" "9200" "" port
  ask SEARCH_TRANSPORT_PORT "Transport port" "9300" "" port
  ask SEARCH_PEERS "Other search nodes" "" "Comma separated host[:port]; blank for a single node" "hosts?"
}

interview_pushproxy() {
  group "Push proxy"
  ask PUSH_PROXY_PORT "Push proxy listen port" "8066" "" port
  interview_network
}

save_answers() {
  local file=$1 k
  {
    printf '# Mattermost Pre-Flight answers: %s on %s, %s\n' "$ROLE" "$HOST_SHORT" "$(date '+%Y-%m-%d %H:%M')"
    printf '# Secrets (%s) are never saved. Add them by hand if you need them,\n' "${SECRET_KEYS// /, }"
    printf '# and keep this file at mode 600.\n\n'
    for k in "${ANS_ORDER[@]}"; do is_secret "$k" && continue; printf '%s=%s\n' "$k" "${ANS[$k]:-}"; done
  } > "$file" && chmod 600 "$file"
}

print_template() {
  local r=$1
  [[ $r == all || -n ${ROLE_NAME[$r]:-} ]] || die "unknown role for --template: $r"
  cat <<EOF
# ─────────────────────────────────────────────────────────────────────────────
#  Mattermost Pre-Flight answer file
#  Usage:  sudo ./mm-preflight.sh -a this-file.conf      (add -y for unattended)
#  Sizing compares this box with Mattermost's published reference architectures:
#  https://docs.mattermost.com/deployment-guide/scale/scaling-for-enterprise
#  Format: KEY=value, one per line. Blank values skip optional checks.
#  Text after " #" is a comment. Quote values that contain " #", e.g. DB_PASSWORD="p #1".
#  Keep at mode 600 if it contains passwords:  chmod 600 this-file.conf
# ─────────────────────────────────────────────────────────────────────────────

# app | db | proxy | rtcd | offloader | search | pushproxy
ROLE=$([[ $r == all ]] && echo app || echo "$r")

# Optional sizing floors (warnings only) and a disk path to check
#MIN_CPU=
#MIN_RAM_GB=
#MIN_DISK_GB=
#DISK_PATH=
#SSH_PORT=22

# Capacity & network performance
TARGET_USERS=                   # expected peak CONCURRENT users (app, db, search roles)
PERF_TEST=no                    # yes = bandwidth test; peers run: --listen perf:18999
PERF_PORT=18999
#PERF_MB=64                     # data sent each way per bandwidth test
#BANDWIDTH_WARN_MBPS=500        # warn below this (engineering default, not Mattermost-published)
#LATENCY_WARN_MS=5              # warn above this average TCP round trip (engineering default)
#LATENCY_FAIL_MS=30             # fail above this
EOF
  if [[ $r == all || $r == app ]]; then cat <<'EOF'

# ── app: Mattermost application server ──────────────────────────────────────
SITE_URL=https://chat.example.com
APP_PEERS=                      # other cluster nodes, comma separated
DB_HOST=db1.example.internal
DB_PORT=5432
DB_NAME=mattermost
DB_USER=mmuser
DB_SSLMODE=prefer               # disable | prefer | require | verify-ca | verify-full
DB_PASSWORD=                    # optional: live login test (needs psql)
DB_REPLICAS=                    # host[:port], comma separated
FILE_STORE=local                # local | nfs | s3
DATA_DIR=/opt/mattermost/data   # local / nfs
S3_ENDPOINT=                    # s3: https://s3.eu-west-2.amazonaws.com or https://minio:9000
S3_BUCKET=
S3_REGION=us-east-1
S3_PATH_STYLE=no                # yes for MinIO
S3_ACCESS_KEY=
S3_SECRET_KEY=
SMTP_HOST=
SMTP_SECURITY=starttls          # starttls | tls | none
SMTP_PORT=587
LDAP_HOST=
LDAP_SECURITY=ldaps             # ldaps | starttls | none
LDAP_PORT=636
LDAP_BIND_DN=
LDAP_BIND_PASSWORD=
LDAP_BASE_DN=
SSO_METADATA_URL=
SEARCH_URL=                     # https://search:9200
SEARCH_USER=
SEARCH_PASSWORD=
REDIS_HOST=                     # host[:port]
CALLS_MODE=integrated           # integrated | rtcd | none
RTC_PORT=8443
ICE_HOST_OVERRIDE=
RTCD_HOSTS=                     # rtcd mode: host[:8045], comma separated
OFFLOADER_URL=                  # http://offloader:4545
STUN_SERVER=stun.global.calls.mattermost.com:3478
PUSH_SERVER=https://push.mattermost.com
AIR_GAPPED=no
OUTBOUND_PROXY=                 # http://proxy:3128
NO_PROXY_LIST=localhost,127.0.0.1
EOF
  fi
  if [[ $r == all || $r == db ]]; then cat <<'EOF'

# ── db: PostgreSQL database server ──────────────────────────────────────────
DB_PORT=5432
PG_MIN_VERSION=15                # 15 for Mattermost v12.0+, 14 for v11.7 ESR
DB_NAME=mattermost
DB_USER=mmuser
APP_NODES=app1.example.internal,app2.example.internal
MAX_OPEN_CONNS=300
DB_PEERS=                       # replication peers
EOF
  fi
  if [[ $r == all || $r == proxy ]]; then cat <<'EOF'

# ── proxy: NGINX / load balancer ────────────────────────────────────────────
SITE_URL=https://chat.example.com
APP_NODES=app1.example.internal:8065,app2.example.internal:8065
TLS_CERT=/etc/pki/tls/certs/chat.example.com.pem
TLS_KEY=/etc/pki/tls/private/chat.example.com.key
EOF
  fi
  if [[ $r == all || $r == rtcd ]]; then cat <<'EOF'

# ── rtcd: Calls RTCD server ─────────────────────────────────────────────────
RTC_PORT=8443
RTCD_API_PORT=8045
ICE_HOST_OVERRIDE=
AIR_GAPPED=no
STUN_SERVER=stun.global.calls.mattermost.com:3478
EOF
  fi
  if [[ $r == all || $r == offloader ]]; then cat <<'EOF'

# ── offloader: Calls recording & transcription ──────────────────────────────
SITE_URL=https://chat.example.com
RTC_TARGET=rtcd1.example.internal:8443
OFFLOADER_PORT=4545
OFFLOADER_USER=calls-offloader
AIR_GAPPED=no
OUTBOUND_PROXY=
NO_PROXY_LIST=localhost,127.0.0.1
EOF
  fi
  if [[ $r == all || $r == search ]]; then cat <<'EOF'

# ── search: Elasticsearch / OpenSearch node ─────────────────────────────────
SEARCH_PORT=9200
SEARCH_TRANSPORT_PORT=9300
SEARCH_PEERS=
EOF
  fi
  if [[ $r == all || $r == pushproxy ]]; then cat <<'EOF'

# ── pushproxy: self-hosted push proxy ───────────────────────────────────────
PUSH_PROXY_PORT=8066
AIR_GAPPED=no
OUTBOUND_PROXY=
NO_PROXY_LIST=localhost,127.0.0.1
EOF
  fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Environment & helpers
# ════════════════════════════════════════════════════════════════════════════
TMPD=""
detect_env() {
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/mm-preflight.XXXXXX") || die "cannot create a temp directory"
  IS_ROOT=0; [[ $EUID -eq 0 ]] && IS_ROOT=1
  HAS_PY=0
  have python3 && python3 -I -c 'import sys; sys.exit(0 if sys.version_info >= (3, 6) else 1)' 2>/dev/null && HAS_PY=1
  FW_STATE=inactive FW_ZONES=""
  if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    if firewall-cmd --state >/dev/null 2>&1; then
      FW_STATE=active
      FW_ZONES=$(firewall-cmd --get-active-zones 2>/dev/null | awk '!/^[[:space:]]/{print $1}' | paste -sd' ' -)
      [[ -z $FW_ZONES ]] && FW_ZONES=$(firewall-cmd --get-default-zone 2>/dev/null)
    else
      FW_STATE=noperm
    fi
  fi
  INTERACTIVE=1
  ((OPT_YES)) && INTERACTIVE=0
  { : < /dev/tty; } 2>/dev/null || INTERACTIVE=0
}

is_ip() { [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }

# url_parse URL → U_SCHEME U_HOST U_PORT
url_parse() {
  local u=$1 rest
  if [[ $u == *://* ]]; then U_SCHEME=${u%%://*}; rest=${u#*://}; else U_SCHEME=https; rest=$u; fi
  U_SCHEME=${U_SCHEME,,}
  rest=${rest%%/*}
  rest=${rest##*@}
  if [[ $rest == *:* ]]; then U_HOST=${rest%:*}; U_PORT=${rest##*:}; else U_HOST=$rest; U_PORT=""; fi
  if [[ -z $U_PORT ]]; then case $U_SCHEME in http) U_PORT=80 ;; *) U_PORT=443 ;; esac; fi
}

# hp_split "host[:port]" default → HP_HOST HP_PORT
hp_split() { if [[ $1 == *:* ]]; then HP_HOST=${1%%:*}; HP_PORT=${1##*:}; else HP_HOST=$1; HP_PORT=$2; fi; }

split_list() { local -n _out=$1; _out=(); local -a _t; local x; IFS=', ' read -r -a _t <<< "${2:-}"; for x in "${_t[@]}"; do [[ -n $x ]] && _out+=("$x"); done; }

resolve4() { if is_ip "$1"; then echo "$1"; else getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; fi; }
local_ips() { ip -o -4 addr show 2>/dev/null | awk '{split($4,a,"/"); print a[1]}'; }

find_pg_bin() {
  if have "$1"; then command -v "$1"; return; fi
  local f; f=$(ls -1d /usr/pgsql-*/bin/"$1" 2>/dev/null | sort -V | tail -1); [[ -n $f ]] && echo "$f"
}

# ════════════════════════════════════════════════════════════════════════════
#  Embedded python helpers (stdlib only)
#  Always run with python3 -I so modules in the current directory are never imported as root.
# ════════════════════════════════════════════════════════════════════════════
read -r -d '' PY_UDP <<'PY' || true
import socket, sys, os, errno
host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
try:
    fam, _, _, _, addr = socket.getaddrinfo(host, port, 0, socket.SOCK_DGRAM)[0]
except socket.gaierror:
    print("DNS"); sys.exit(0)
s = socket.socket(fam, socket.SOCK_DGRAM)
s.settimeout(max(timeout / 3, 0.5))
tok = ("MMPF-" + os.urandom(6).hex()).encode()
try:
    s.connect(addr)
    for _ in range(3):
        s.send(tok)
        try:
            data = s.recv(4096)
            print("ECHO" if data == tok else "REPLY"); sys.exit(0)
        except socket.timeout:
            continue
    print("TIMEOUT")
except ConnectionRefusedError:
    print("REFUSED")
except OSError as e:
    if e.errno in (errno.EHOSTUNREACH, errno.ENETUNREACH, errno.EACCES, errno.EPERM):
        print("UNREACH")
    else:
        print("ERROR " + (e.strerror or str(e)))
PY

read -r -d '' PY_STUN <<'PY' || true
import socket, sys, os, struct
host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
try:
    addr = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
except socket.gaierror:
    print("DNS"); sys.exit(0)
tid = os.urandom(12)
req = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + tid
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(max(timeout / 2, 0.5))
data = None
for _ in range(2):
    try:
        s.sendto(req, addr); data, _ = s.recvfrom(2048); break
    except socket.timeout:
        continue
    except OSError as e:
        print("ERROR " + (e.strerror or str(e))); sys.exit(0)
if not data:
    print("TIMEOUT"); sys.exit(0)
if len(data) < 20 or struct.unpack("!H", data[:2])[0] != 0x0101 or data[8:20] != tid:
    print("BADREPLY"); sys.exit(0)
i = 20
while i + 4 <= len(data):
    at, al = struct.unpack("!HH", data[i:i+4]); v = data[i+4:i+4+al]
    if at in (0x0020, 0x8020) and len(v) >= 8 and v[1] == 1:
        ip = struct.unpack("!I", v[4:8])[0] ^ 0x2112A442
        print("OK " + socket.inet_ntoa(struct.pack("!I", ip))); sys.exit(0)
    if at == 0x0001 and len(v) >= 8 and v[1] == 1:
        print("OK " + socket.inet_ntoa(v[4:8])); sys.exit(0)
    i += 4 + al + ((4 - al % 4) % 4)
print("NOADDR")
PY

read -r -d '' PY_PGSSL <<'PY' || true
import socket, sys, struct
h, p, t = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
try:
    s = socket.create_connection((h, p), timeout=t)
    s.sendall(struct.pack("!ii", 8, 80877103))
    r = s.recv(1)
    print({b"S": "SSL", b"N": "NOSSL"}.get(r, "OTHER"))
except socket.timeout:
    print("TIMEOUT")
except OSError as e:
    print("ERROR " + (e.strerror or str(e)))
PY

read -r -d '' PY_S3 <<'PY' || true
import os, sys, re, hashlib, hmac, datetime, urllib.request, urllib.parse, urllib.error
E = os.environ
endpoint = E["MMPF_S3_ENDPOINT"].rstrip("/")
bucket, region = E["MMPF_S3_BUCKET"], (E.get("MMPF_S3_REGION") or "us-east-1")
ak, sk, key = E["MMPF_S3_AK"], E["MMPF_S3_SK"], E["MMPF_S3_KEY"]
path_style, timeout = E.get("MMPF_S3_PATH") == "yes", float(E.get("MMPF_TIMEOUT", "10"))
if "://" not in endpoint:
    endpoint = "https://" + endpoint
u = urllib.parse.urlparse(endpoint)
if path_style:
    host, path = u.netloc, "/%s/%s" % (bucket, key)
else:
    host, path = "%s.%s" % (bucket, u.netloc), "/" + key
def hm(k, m): return hmac.new(k, m.encode(), hashlib.sha256).digest()
def call(method, body=b""):
    t = datetime.datetime.now(datetime.timezone.utc)
    amz, day = t.strftime("%Y%m%dT%H%M%SZ"), t.strftime("%Y%m%d")
    ph = hashlib.sha256(body).hexdigest()
    uri = urllib.parse.quote(path, safe="/-_.~")
    hdr = {"host": host, "x-amz-content-sha256": ph, "x-amz-date": amz}
    sh = ";".join(sorted(hdr))
    ch = "".join("%s:%s\n" % (k, hdr[k]) for k in sorted(hdr))
    creq = "\n".join([method, uri, "", ch, sh, ph])
    scope = "%s/%s/s3/aws4_request" % (day, region)
    sts = "\n".join(["AWS4-HMAC-SHA256", amz, scope, hashlib.sha256(creq.encode()).hexdigest()])
    k = hm(("AWS4" + sk).encode(), day); k = hm(k, region); k = hm(k, "s3"); k = hm(k, "aws4_request")
    sig = hmac.new(k, sts.encode(), hashlib.sha256).hexdigest()
    r = urllib.request.Request("%s://%s%s" % (u.scheme, host, uri), data=(body if method == "PUT" else None), method=method)
    r.add_header("x-amz-content-sha256", ph); r.add_header("x-amz-date", amz)
    if method == "PUT": r.add_header("Content-Type", "text/plain")
    r.add_header("Authorization", "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (ak, scope, sh, sig))
    with urllib.request.urlopen(r, timeout=timeout) as resp:
        return resp.read()
body = ("Mattermost Pre-Flight write test " + key).encode()
step, wrote = "PUT", False
try:
    call("PUT", body); wrote = True
    step = "GET"
    if call("GET") != body:
        print("FAIL GET content-mismatch"); sys.exit(0)
    step = "DELETE"; call("DELETE"); wrote = False
    print("OK")
except urllib.error.HTTPError as e:
    b = e.read().decode(errors="replace")
    c = re.search(r"<Code>([^<]+)</Code>", b); m = re.search(r"<Message>([^<]+)</Message>", b)
    print("FAIL %s %s %s %s" % (step, e.code, c.group(1) if c else "HTTPError", m.group(1) if m else ""))
except urllib.error.URLError as e:
    print("FAIL %s 0 Connection %s" % (step, e.reason))
except Exception as e:
    print("FAIL %s 0 Error %s" % (step, e))
finally:
    if wrote:
        try: call("DELETE")
        except Exception: pass
PY

read -r -d '' PY_RTT <<'PY' || true
import socket, sys, time
h, p, n, t = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
try:
    fam, _, _, _, addr = socket.getaddrinfo(h, p, 0, socket.SOCK_STREAM)[0]
except socket.gaierror:
    print("DNS"); sys.exit(0)
rt, lost, refused, err, streak = [], 0, 0, "", 0
for _ in range(n):
    s = socket.socket(fam, socket.SOCK_STREAM); s.settimeout(t)
    t0 = time.perf_counter()
    try:
        s.connect(addr); rt.append((time.perf_counter() - t0) * 1000); streak = 0
    except ConnectionRefusedError:            # a RST is still a full round trip
        rt.append((time.perf_counter() - t0) * 1000); refused += 1; streak = 0
    except socket.timeout:
        lost += 1; streak += 1; err = "timed out"
    except OSError as e:
        lost += 1; streak += 1; err = e.strerror or str(e)
    finally:
        s.close()
    if streak >= 3: break
    time.sleep(0.05)
if not rt:
    print("NONE " + err); sys.exit(0)
jit = sum(abs(rt[i] - rt[i - 1]) for i in range(1, len(rt))) / max(1, len(rt) - 1)
print("OK %.2f %.2f %.2f %.2f %d %d %d" % (min(rt), sum(rt) / len(rt), max(rt), jit, lost, len(rt) + lost, refused))
PY

read -r -d '' PY_PERF <<'PY' || true
import socket, sys, time
h, p, mb, t = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
n = mb * 1024 * 1024
def conn():
    s = socket.create_connection((h, p), timeout=t); s.settimeout(120); return s
try:
    s = conn()
except ConnectionRefusedError:
    print("NOLISTENER"); sys.exit(0)
except socket.timeout:
    print("TIMEOUT"); sys.exit(0)
except OSError as e:
    print("ERROR " + (e.strerror or str(e))); sys.exit(0)
try:
    buf = b"\0" * 65536
    s.sendall(b"MMPF-PERF UP %d\n" % n)
    t0, sent = time.perf_counter(), 0
    while sent < n:
        k = min(len(buf), n - sent); s.sendall(buf[:k]); sent += k
    s.shutdown(socket.SHUT_WR); r = s.recv(64); up = time.perf_counter() - t0; s.close()
    if not r.startswith(b"OK"):
        print("PROTO"); sys.exit(0)
    s = conn(); s.sendall(b"MMPF-PERF DOWN %d\n" % n)
    t0, got = time.perf_counter(), 0
    while True:
        d = s.recv(262144)
        if not d: break
        got += len(d)
    down = time.perf_counter() - t0; s.close()
    print("OK %.0f %.0f" % (n * 8 / up / 1e6, got * 8 / down / 1e6))
except socket.timeout:
    print("ERROR transfer timed out")
except (BrokenPipeError, ConnectionResetError):
    print("PROTO")
except OSError as e:
    print("ERROR " + (e.strerror or str(e)))
PY

read -r -d '' PY_LISTEN <<'PY' || true
import socket, sys, threading, time
specs, duration, ok, bad = sys.argv[1].split(","), int(sys.argv[2]), sys.argv[3], sys.argv[4]
def log(mark, msg): print("  %s  %s  %s" % (mark, time.strftime("%H:%M:%S"), msg), flush=True)
def bind(kind, port):
    st = socket.SOCK_DGRAM if kind == "udp" else socket.SOCK_STREAM
    try:
        s = socket.socket(socket.AF_INET6, st)
        s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("::", port))
    except OSError as e:
        if getattr(e, "errno", None) in (98, 13): raise
        s = socket.socket(socket.AF_INET, st)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", port))
    if kind != "udp": s.listen(32)
    return s
def peer(a): return a[0].replace("::ffff:", "")
def serve_tcp(s, port):
    while True:
        c, a = s.accept()
        log(ok, "TCP %-5d  connection from %s" % (port, peer(a)))
        try: c.sendall(b"MMPF-OK\n")
        except OSError: pass
        c.close()
def perf_conn(c, a, port):
    try:
        c.settimeout(120); f = b""
        while b"\n" not in f:
            d = c.recv(256)
            if not d: return
            f += d
        line, _, rest = f.partition(b"\n"); parts = line.split()
        if len(parts) != 3 or parts[0] != b"MMPF-PERF": return
        n = min(int(parts[2]), 1 << 30); t0 = time.perf_counter()
        if parts[1] == b"UP":
            got = len(rest)
            while got < n:
                d = c.recv(262144)
                if not d: break
                got += len(d)
            c.sendall(b"OK %d\n" % got); what = "received"
        else:
            buf, got = b"\0" * 262144, 0
            while got < n:
                k = min(len(buf), n - got); c.sendall(buf[:k]); got += k
            what = "sent"
        secs = max(time.perf_counter() - t0, 1e-6)
        log(ok, "PERF %-5d %s %d MB %s %s · %.0f Mbit/s" % (port, what, got >> 20, "from" if what == "received" else "to", peer(a), got * 8 / secs / 1e6))
    except (OSError, ValueError):
        pass
    finally:
        c.close()
def serve_perf(s, port):
    while True:
        c, a = s.accept()
        threading.Thread(target=perf_conn, args=(c, a, port), daemon=True).start()
def serve_udp(s, port):
    while True:
        d, a = s.recvfrom(4096)
        log(ok, "UDP %-5d  datagram from %s (echoed back)" % (port, peer(a)))
        try: s.sendto(d, a)
        except OSError: pass
n = 0
for spec in specs:
    kind, _, port = spec.partition(":"); port = int(port)
    try:
        s = bind(kind, port)
    except OSError as e:
        log(bad, "%s/%d not opened: %s" % (kind, port, e.strerror)); continue
    fn = {"tcp": serve_tcp, "udp": serve_udp, "perf": serve_perf}[kind]
    threading.Thread(target=fn, args=(s, port), daemon=True).start()
    log(ok, "listening on %s/%d" % (kind, port)); n += 1
if not n: sys.exit(1)
print(flush=True)
try:
    time.sleep(duration); print("\n  Time limit reached. Listeners closed.")
except KeyboardInterrupt:
    print("\n  Stopped. Listeners closed.")
PY

# ════════════════════════════════════════════════════════════════════════════
#  Check result API
# ════════════════════════════════════════════════════════════════════════════
S_STATUS="" S_DETAIL="" S_FIX="" S_DOC=""
pass() { S_STATUS=PASS; S_DETAIL=${1:-}; S_FIX=""; S_DOC=""; }
warn() { S_STATUS=WARN; S_DETAIL=${1:-}; S_FIX=${2:-}; S_DOC=${3:-}; }
fail() { S_STATUS=FAIL; S_DETAIL=${1:-}; S_FIX=${2:-}; S_DOC=${3:-}; }
skip() { S_STATUS=SKIP; S_DETAIL=${1:-}; S_FIX=${2:-}; S_DOC=${3:-}; }
info() { S_STATUS=INFO; S_DETAIL=${1:-}; S_FIX=${2:-}; S_DOC=${3:-}; }
sev()  { local s=$1; shift; if [[ $s == warn ]]; then warn "$@"; else fail "$@"; fi; }
needs_py() { ((HAS_PY)) && return 0; skip "python3 not available, so this check was skipped" "dnf install -y python3"; return 1; }

# ════════════════════════════════════════════════════════════════════════════
#  System checks
# ════════════════════════════════════════════════════════════════════════════
chk_os() {
  [[ -r /etc/os-release ]] || { warn "cannot read /etc/os-release" "Run on RHEL 9 or 10" "$DOC_REQS"; return; }
  local id ver name
  IFS=$'\t' read -r id ver name <<< "$( . /etc/os-release; printf '%s\t%s\t%s\n' "${ID:-}" "${VERSION_ID:-}" "${PRETTY_NAME:-}" )"
  case $id in
    rhel|rocky|almalinux|ol|centos)
      if [[ ${ver%%.*} == 9 || ${ver%%.*} == 10 ]]; then pass "$name"
      else warn "$name. This tool targets RHEL 9 and 10" "Confirm the OS is supported for this Mattermost version" "$DOC_REQS"; fi ;;
    *) warn "$name is not a RHEL-family OS" "Treat the results as indicative. Package and firewall advice assumes RHEL" "$DOC_REQS" ;;
  esac
}

chk_arch() {
  local a; a=$(uname -m)
  case $a in x86_64|aarch64) pass "$a" ;; *) fail "$a is not supported" "Use x86_64 or arm64 (aarch64)" "$DOC_REQS" ;; esac
}

chk_cpu() {
  local n; n=$(nproc 2>/dev/null || echo 0)
  if (( n >= $1 )); then pass "$n vCPU"; else warn "$n vCPU (expected at least $1)" "Size CPU for your user count and workload" "$DOC_REQS"; fi
}

chk_ram() {
  local kb gb; kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  gb=$(awk -v k="$kb" 'BEGIN{printf "%.1f", k/1048576}')
  if (( kb >= $1 * 1048576 * 92 / 100 )); then pass "$gb GB"
  else warn "$gb GB (expected at least $1 GB)" "Add memory to meet the sizing for your user count" "$DOC_REQS"; fi
}

chk_disk() {
  local path=$1 min=$2 p=$1 avail mnt gb
  while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
  avail=$(df -Pk "$p" 2>/dev/null | awk 'NR==2{print $4}'); mnt=$(df -Pk "$p" 2>/dev/null | awk 'NR==2{print $6}')
  [[ -n $avail ]] || { warn "cannot read free space for $path"; return; }
  gb=$(( avail / 1048576 ))
  local where="$mnt"; [[ $p != "$path" ]] && where="$mnt ($path doesn't exist yet)"
  if (( gb >= min )); then pass "$gb GB free on $where"
  else warn "$gb GB free on $where (expected at least $min GB)" "Extend the volume holding $path" "$DOC_REQS"; fi
}

chk_ntp() {
  if have chronyc; then
    local out leap off src
    out=$(timeout "$OPT_TIMEOUT" chronyc -n tracking 2>/dev/null)
    if [[ -z $out ]]; then
      fail "chronyd is not responding" "systemctl enable --now chronyd" "$DOC_REQS"; return
    fi
    leap=$(awk -F': *' '/^Leap status/{print $2}' <<< "$out")
    off=$(awk '/^System time/{print $4}' <<< "$out")
    src=$(awk -F': *' '/^Reference ID/{print $2}' <<< "$out" | awk '{print $2}' | tr -d '()')
    if [[ $leap != Normal* ]]; then
      fail "clock not synchronised (${leap:-unknown})" "Check sources with 'chronyc sources -v' and allow UDP 123 to your NTP servers" "$DOC_REQS"
    elif awk -v o="${off:-0}" 'BEGIN{exit !(o > 1)}'; then
      warn "clock is ${off}s from NTP time" "Let chrony converge or run 'chronyc makestep'" "$DOC_REQS"
    else
      pass "synchronised · offset ${off}s${src:+ · $src}"
    fi
  elif have timedatectl; then
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null) == yes ]]; then pass "synchronised (timedatectl)"
    else fail "clock not synchronised" "dnf install -y chrony && systemctl enable --now chronyd" "$DOC_REQS"; fi
  else
    warn "no time service found" "dnf install -y chrony && systemctl enable --now chronyd" "$DOC_REQS"
  fi
}

chk_self_dns() {
  local fqdn ips; fqdn=$(hostname -f 2>/dev/null || hostname)
  ips=$(getent ahosts "$fqdn" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)
  if [[ -z $ips ]]; then
    warn "$fqdn does not resolve" "Add a DNS record (or /etc/hosts entry) so peers can reach this server by name" "$DOC_NETWORK"
  elif ! grep -qvE '^(127\.|::1$)' <<< "${ips//,/$'\n'}"; then
    warn "$fqdn resolves only to loopback ($ips)" "Map the hostname to this server's real IP in DNS or /etc/hosts" "$DOC_NETWORK"
  else
    pass "$fqdn resolves to $ips"
  fi
}

chk_selinux() {
  have getenforce || { info "SELinux tools not installed"; return; }
  local m; m=$(getenforce 2>/dev/null)
  case $m in
    Enforcing) info "Enforcing. Label the binaries and allow the ports after install" "" "$DOC_RHEL" ;;
    *) info "${m:-unknown}" ;;
  esac
}

chk_firewalld_state() {
  case $FW_STATE in
    active) info "firewalld active · zone(s): ${FW_ZONES:-default}" ;;
    noperm) info "firewalld active (run as root to inspect rules)" ;;
    *)      info "firewalld inactive. Network firewalls must still allow the ports below" ;;
  esac
}

fw_allows() {
  local p=$1 proto=$2 z s
  FW_HIT=""
  for z in $FW_ZONES; do
    if firewall-cmd --zone="$z" --query-port="$p/$proto" >/dev/null 2>&1; then FW_HIT="zone $z"; return 0; fi
    for s in $(firewall-cmd --zone="$z" --list-services 2>/dev/null); do
      if firewall-cmd --permanent --service="$s" --get-ports 2>/dev/null | tr ' ' '\n' | grep -qx "$p/$proto"; then
        FW_HIT="zone $z, service $s"; return 0
      fi
    done
    if firewall-cmd --zone="$z" --list-rich-rules 2>/dev/null | grep -q "port=\"$p\" protocol=\"$proto\""; then
      FW_HIT="zone $z, rich rule"; return 0
    fi
  done
  return 1
}

chk_fw() {
  local p=$1 proto=$2 who=$3 doc=${4:-$DOC_NETWORK}
  case $FW_STATE in
    inactive) skip "firewalld inactive. Confirm network firewalls allow $p/$proto from $who"; return ;;
    noperm)   skip "run as root to read firewalld rules"; return ;;
  esac
  if fw_allows "$p" "$proto"; then pass "open ($FW_HIT)"
  else
    fail "$p/$proto is not open in zone(s) ${FW_ZONES}" \
      "firewall-cmd --permanent --add-port=$p/$proto && firewall-cmd --reload  (use a rich rule to limit sources to $who)" "$doc"
  fi
}

INBOUND_FREE=()
chk_listen() {
  local p=$1 proto=$2 svc=$3 expect=$4 doc=${5:-$DOC_NETWORK} flag=t out proc
  [[ $proto == udp ]] && flag=u
  have ss || { skip "ss not installed (dnf install -y iproute)"; return; }
  out=$(ss -H -ln${flag}p "sport = :$p" 2>/dev/null)
  if [[ -z $out ]]; then pass "free"; INBOUND_FREE+=("$proto:$p"); return; fi
  proc=$(grep -o 'users:(("[^"]*"' <<< "$out" | head -1 | cut -d'"' -f2)
  if [[ -n $proc && -n $expect && $proc =~ $expect ]]; then pass "in use by $proc (expected)"
  else warn "already in use by ${proc:-another process (run as root to see which)}" \
            "Stop the conflicting service, or move $svc to another port" "$doc"; fi
}

chk_ssh() {
  local p=$1
  if ! systemctl is-active --quiet sshd 2>/dev/null; then
    warn "sshd is not running" "systemctl enable --now sshd (needed for remote administration)" "$DOC_RHEL"; return
  fi
  if have ss && [[ -z $(ss -H -ltn "sport = :$p" 2>/dev/null) ]]; then
    warn "sshd active but not listening on $p" "Check Port in /etc/ssh/sshd_config or set SSH_PORT"; return
  fi
  if [[ $FW_STATE == active ]] && ! fw_allows "$p" tcp; then
    warn "sshd on $p, but firewalld does not allow it" "firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload"; return
  fi
  pass "sshd listening on $p"
}

chk_nofile() {
  local min=$1 nr fm; nr=$(sysctl -n fs.nr_open 2>/dev/null || echo 0); fm=$(sysctl -n fs.file-max 2>/dev/null || echo 0)
  if (( nr >= min && fm >= min )); then pass "kernel allows $nr · set LimitNOFILE=$min in the unit"
  else warn "fs.nr_open=$nr fs.file-max=$fm (need ≥ $min)" "echo 'fs.file-max = 1048576' > /etc/sysctl.d/99-mattermost.conf && sysctl --system"; fi
}

chk_root() {
  if ((IS_ROOT)); then pass "running as root, so all checks can run"
  else warn "not running as root" "Re-run with sudo: firewall, process-owner, pg_hba and write tests are limited"; fi
}

chk_sysctl() {
  local key=$1 min=$2 s=${3:-warn} doc=${4:-} v
  v=$(sysctl -n "$key" 2>/dev/null) || { skip "$key not available"; return; }
  if (( v >= min )); then pass "$key = $v"
  else sev "$s" "$key = $v (needs ≥ $min)" \
       "echo '$key = $min' >> /etc/sysctl.d/99-mattermost.conf && sysctl --system" "$doc"; fi
}

chk_swap() {
  local s; s=$(swapon --noheadings --show=NAME 2>/dev/null | paste -sd, -)
  if [[ -z $s ]]; then pass "disabled"
  else warn "enabled ($s)" "Disable swap (swapoff -a, remove from /etc/fstab) or set bootstrap.memory_lock: true" "$DOC_SEARCH"; fi
}

chk_tools_required() {
  local -a miss=(); local b
  for b in curl openssl timeout ss getent awk sed grep findmnt df stat runuser; do have "$b" || miss+=("$b"); done
  if ((${#miss[@]})); then
    fail "missing: ${miss[*]}" "dnf install -y curl openssl coreutils iproute util-linux gawk" "$DOC_RHEL"
  elif ((!HAS_PY)); then
    warn "python3 missing. UDP, STUN, S3 and PostgreSQL TLS probes will be skipped" "dnf install -y python3"
  else
    pass "curl, openssl, ss, python3 $(python3 -I -c 'import platform; print(platform.python_version())')"
  fi
}

chk_tools_optional() {
  local -a want=() miss=() ok=(); local w bin pkg why
  case $ROLE in
    app) want+=("psql:postgresql:database login test")
         [[ -n $(get LDAP_BIND_DN) ]] && want+=("ldapsearch:openldap-clients:LDAP bind test") ;;
    db)  want+=("psql:postgresql:local server inspection") ;;
  esac
  if ((${#want[@]} == 0)); then pass "none needed for this role"; return; fi
  for w in "${want[@]}"; do
    IFS=: read -r bin pkg why <<< "$w"
    if [[ -n $(find_pg_bin "$bin") ]]; then ok+=("$bin"); else miss+=("$bin (dnf install $pkg, for the $why)"); fi
  done
  if ((${#miss[@]})); then info "not installed: ${miss[*]}" "Install them for deeper checks, or accept the skipped tests"
  else pass "${ok[*]} available"; fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Network checks
# ════════════════════════════════════════════════════════════════════════════
chk_dns() {
  local h=$1 doc=${2:-$DOC_NETWORK} ips
  if is_ip "$h"; then pass "IP address, no lookup needed"; return; fi
  ips=$(timeout "$OPT_TIMEOUT" getent ahosts "$h" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)
  if [[ -n $ips ]]; then pass "$ips"
  else fail "$h does not resolve" "Add a DNS record (or /etc/hosts entry) for $h, and check /etc/resolv.conf" "$doc"; fi
}

# tcp_probe host port → TP_RC (0 ok, 1 refused, 2 rejected/no route, 3 dns, 4 timeout, 9 other) TP_MS TP_ERR
tcp_probe() {
  local t0 rc; t0=$(now_ms)
  TP_ERR=$(timeout "$OPT_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>&1 >/dev/null); rc=$?
  TP_MS=$(( $(now_ms) - t0 ))
  if ((rc == 0)); then TP_RC=0
  elif ((rc == 124)); then TP_RC=4
  else
    case $TP_ERR in
      *refused*) TP_RC=1 ;;
      *"No route"*|*unreachable*|*"not permitted"*) TP_RC=2 ;;
      *"not known"*|*"Name or service"*|*"Temporary failure in name"*) TP_RC=3 ;;
      *) TP_RC=9 ;;
    esac
  fi
}

tcp_result() {  # host port service soft doc   (uses TP_*)
  local h=$1 p=$2 svc=$3 soft=$4 doc=$5
  case $TP_RC in
    0) pass "open · ${TP_MS} ms" ;;
    1) if ((soft)); then
         warn "$h is reachable but nothing is listening on $p yet" \
              "Expected if $svc isn't installed yet. To prove the firewall path now, run on $h:  sudo ./$SELF --listen tcp:$p   then re-run this check" "$doc"
       else
         fail "connection refused: $svc is not listening on $h:$p" "Start $svc, and make sure it binds to a network interface (not only 127.0.0.1)" "$doc"
       fi ;;
    2) fail "rejected by a firewall REJECT rule, or no route to $h" "Open TCP $p on $h's firewall (firewall-cmd) and any network firewall in between" "$doc" ;;
    3) fail "$h does not resolve" "Fix DNS for $h" "$doc" ;;
    4) fail "timed out after ${OPT_TIMEOUT}s. A firewall is probably dropping the packets" "Allow TCP $p from $HOST_SHORT to $h on every firewall / security group in the path" "$doc" ;;
    *) fail "unreachable: $(oneline "$TP_ERR" 80)" "Check routing and firewalls between $HOST_SHORT and $h" "$doc" ;;
  esac
}

chk_tcp() {
  local h=$1 p=$2 svc=${3:-the service} soft=${4:-0} doc=${5:-$DOC_NETWORK}
  tcp_probe "$h" "$p"; tcp_result "$h" "$p" "$svc" "$soft" "$doc"
}

chk_udp() {
  local h=$1 p=$2 svc=${3:-the service} doc=${4:-$DOC_NETWORK} r
  needs_py || return
  r=$(timeout $((OPT_TIMEOUT + 3)) python3 -I -c "$PY_UDP" "$h" "$p" "$OPT_TIMEOUT" 2>/dev/null)
  case $r in
    ECHO|REPLY) pass "round trip confirmed" ;;
    REFUSED)    warn "$h replied 'port unreachable', so the path is open but nothing is listening on $p/udp yet" \
                     "Expected if $svc isn't running yet. For a definitive test run on $h:  sudo ./$SELF --listen udp:$p" "$doc" ;;
    UNREACH)    fail "rejected by a firewall (ICMP unreachable)" "Allow UDP $p from $HOST_SHORT to $h on host and network firewalls" "$doc" ;;
    TIMEOUT)    warn "no reply. UDP stays silent both when filtered and when nothing echoes" \
                     "Run on $h:  sudo ./$SELF --listen udp:$p   then re-run for a definitive answer" "$doc" ;;
    DNS)        fail "$h does not resolve" "Fix DNS for $h" "$doc" ;;
    *)          warn "inconclusive: ${r:-no output}" "Run on $h:  sudo ./$SELF --listen udp:$p   then re-run" "$doc" ;;
  esac
}

chk_tls() {  # host port [starttls] [sni] [severity] [doc]
  local h=$1 p=$2 st=${3:-} sni=${4:-$1} s=${5:-fail} doc=${6:-$DOC_TLS}
  local -a args=(-connect "$h:$p" -servername "$sni" -verify_hostname "$sni")
  [[ -n $st ]] && args+=(-starttls "$st")
  local out cert end vcode vmsg why
  out=$(timeout $((OPT_TIMEOUT + 5)) openssl s_client "${args[@]}" < /dev/null 2>&1)
  cert=$(awk '/-----BEGIN CERTIFICATE-----/{f=1} f{print} /-----END CERTIFICATE-----/{exit}' <<< "$out")
  if [[ -z $cert ]]; then
    why=$(grep -m1 -Ei "didn't find|refused|errno|timed out|wrong version|unexpected|alert|error" <<< "$out")
    sev "$s" "TLS handshake failed${why:+: $(oneline "$why" 70)}" \
        "Confirm $h:$p speaks TLS$([[ -n $st ]] && echo " via STARTTLS") and the port / security mode is right" "$doc"
    return
  fi
  end=$(openssl x509 -noout -enddate <<< "$cert" 2>/dev/null | cut -d= -f2)
  vcode=$(sed -n 's/^[[:space:]]*Verify return code: \([0-9]*\).*/\1/p' <<< "$out" | tail -1)
  vmsg=$(sed -n 's/^[[:space:]]*Verify return code: [0-9]* (\(.*\))/\1/p' <<< "$out" | tail -1)
  if ! openssl x509 -noout -checkend 0 <<< "$cert" >/dev/null 2>&1; then
    fail "certificate expired ($end)" "Renew the certificate on $h" "$doc"
  elif [[ ${vcode:-1} != 0 ]]; then
    sev "$s" "certificate not trusted: ${vmsg:-unknown}" \
        "Internal CA? cp ca.pem /etc/pki/ca-trust/source/anchors/ && update-ca-trust. Name mismatch? Reissue the cert for $sni" "$doc"
  elif ! openssl x509 -noout -checkend 2592000 <<< "$cert" >/dev/null 2>&1; then
    warn "trusted, but expires within 30 days ($end)" "Renew before $end" "$doc"
  else
    pass "trusted · expires $(date -d "$end" +%Y-%m-%d 2>/dev/null || echo "$end")"
  fi
}

curl_cfg_user() {  # write a curl config with credentials (keeps them out of ps)
  local f="$TMPD/curl.cfg" u=${1//\\/\\\\} pw=${2//\\/\\\\}
  u=${u//\"/\\\"}; pw=${pw//\"/\\\"}
  printf 'user = "%s:%s"\n' "$u" "$pw" > "$f"; printf '%s' "$f"
}

# http_get URL [body-file] [user] [pass] → H_RC H_CODE H_TIME H_ERR
http_get() {
  local url=$1 body=${2:-/dev/null} user=${3:-} pw=${4:-} out
  local -a args=(-sS -o "$body" -w '%{http_code} %{time_total}' --connect-timeout "$OPT_TIMEOUT" --max-time $((OPT_TIMEOUT * 2)))
  [[ -n $user ]] && args+=(-K "$(curl_cfg_user "$user" "$pw")")
  out=$(curl "${args[@]}" "$url" 2> "$TMPD/curl.err"); H_RC=$?
  H_CODE=${out%% *}; H_TIME=${out#* }; H_ERR=$(oneline "$(cat "$TMPD/curl.err" 2>/dev/null)" 90)
  rm -f "$TMPD/curl.cfg"
}

http_result() {  # url soft doc
  local url=$1 soft=$2 doc=$3 ms via=""
  [[ -n ${HTTPS_PROXY:-} ]] && ! noproxy_covers "$U_HOST" "${NO_PROXY:-}" && via=" · via proxy"
  case $H_RC in
    0)  ms=$(awk -v t="$H_TIME" 'BEGIN{printf "%d", t*1000}'); pass "HTTP $H_CODE · ${ms} ms$via" ;;
    6)  fail "cannot resolve $U_HOST" "Fix DNS for $U_HOST" "$doc" ;;
    5)  fail "cannot resolve the outbound proxy" "Check OUTBOUND_PROXY" "$doc" ;;
    7)  if ((soft)); then warn "nothing is listening at $U_HOST:$U_PORT yet" \
            "Expected if it isn't installed yet. To prove the path now run on $U_HOST:  sudo ./$SELF --listen tcp:$U_PORT" "$doc"
        else fail "could not connect to $U_HOST:$U_PORT$via" "Check the service is running and firewalls allow TCP $U_PORT" "$doc"; fi ;;
    28) fail "timed out$via" "Allow TCP $U_PORT to $U_HOST (or via the proxy) on every firewall in the path" "$doc" ;;
    35|51|53|54|58|59|60|77|80|83|90|91)
        fail "TLS problem: $H_ERR" "Internal CA? cp ca.pem /etc/pki/ca-trust/source/anchors/ && update-ca-trust" "$DOC_TLS" ;;
    52|56) fail "connection reset / empty reply$via" "A proxy, IPS or firewall may be interfering; check the proxy allows $U_HOST" "$doc" ;;
    *)  fail "curl error $H_RC: $H_ERR" "Check connectivity to $U_HOST:$U_PORT" "$doc" ;;
  esac
}

chk_http() {  # url [doc] [soft]
  local url=$1 doc=${2:-$DOC_NETWORK} soft=${3:-0}
  url_parse "$url"; http_get "$url"; http_result "$url" "$soft" "$doc"
}

noproxy_covers() {
  local h=$1 e; local -a ents; IFS=', ' read -r -a ents <<< "${2:-}"
  for e in "${ents[@]}"; do
    [[ -z $e ]] && continue
    [[ $e == '*' ]] && return 0
    e=${e#\*}; e=${e#.}
    [[ $h == "$e" || $h == *".$e" ]] && return 0
  done
  return 1
}

chk_noproxy() {
  local -a hosts miss=(); local h
  split_list hosts "$1"
  if ((${#hosts[@]} == 0)); then pass "no internal HTTP services configured"; return; fi
  for h in "${hosts[@]}"; do noproxy_covers "$h" "$(get NO_PROXY_LIST)" || miss+=("$h"); done
  if ((${#miss[@]})); then
    local m; m=$(IFS=,; echo "${miss[*]}")
    warn "would be sent via the proxy: $m" "Add them to NO_PROXY in the service unit: NO_PROXY=$(get NO_PROXY_LIST),$m" "$DOC_NETWORK"
  else pass "internal services bypass the proxy"; fi
}

chk_stun() {
  local hp=$1 ice=${2:-} r pub
  needs_py || return
  hp_split "$hp" 3478
  r=$(timeout $((OPT_TIMEOUT + 3)) python3 -I -c "$PY_STUN" "$HP_HOST" "$HP_PORT" "$OPT_TIMEOUT" 2>/dev/null)
  case $r in
    OK*) pub=${r#OK }
         if [[ -n $ice ]]; then
           if resolve4 "$ice" | grep -qx "$pub"; then pass "public IP $pub matches ICE host override"
           else warn "public IP is $pub, but ICE host override $ice resolves to $(resolve4 "$ice" | paste -sd, -)" \
                     "Set ICE host override to the address clients use to reach this server" "$DOC_CALLS"; fi
         elif local_ips | grep -qx "$pub"; then pass "public IP $pub (no NAT)"
         else warn "behind NAT, public IP is $pub" "Set the Calls ICE host override to $pub (or its DNS name)" "$DOC_CALLS"; fi ;;
    TIMEOUT) warn "no STUN reply from $HP_HOST:$HP_PORT" "Allow outbound UDP $HP_PORT, or set ICE host override manually and clear the STUN server" "$DOC_CALLS" ;;
    DNS)     fail "$HP_HOST does not resolve" "Fix DNS, or clear STUN_SERVER" "$DOC_CALLS" ;;
    *)       warn "STUN probe inconclusive: ${r:-no output}" "" "$DOC_CALLS" ;;
  esac
}

chk_site_live() {
  local url=$1
  url_parse "$url"
  tcp_probe "$U_HOST" "$U_PORT"
  if ((TP_RC != 0)); then info "not reachable yet on $U_HOST:$U_PORT, which is expected until the proxy is live"; return; fi
  if [[ $U_SCHEME == https ]]; then chk_tls "$U_HOST" "$U_PORT" "" "$U_HOST" fail "$DOC_TLS"; else
    warn "site URL uses plain HTTP" "Serve Mattermost over HTTPS (required by Calls and the mobile apps)" "$DOC_TLS"; return; fi
  if [[ $S_STATUS == PASS ]]; then
    http_get "${url%/}/api/v4/system/ping"
    [[ $H_RC == 0 && $H_CODE == 200 ]] && S_DETAIL+=" · Mattermost responding"
  fi
}

chk_site_local() {
  local h=$1 ips; ips=$(resolve4 "$h")
  [[ -z $ips ]] && { fail "$h does not resolve" "Create the DNS record for the site" "$DOC_NGINX"; return; }
  local lips x hit=0; lips=$(local_ips)
  for x in $ips; do grep -qxF "$x" <<< "$lips" && hit=1; done
  if ((hit)); then pass "resolves to this server ($(paste -sd, - <<< "$ips"))"
  else info "resolves to $(paste -sd, - <<< "$ips") , not a local address (fine if a VIP or load balancer sits in front)"; fi
}

# ── Database (from an app server) ───────────────────────────────────────────
chk_pg_ssl() {
  local h=$1 p=$2 mode=$3 r
  needs_py || return
  r=$(timeout $((OPT_TIMEOUT + 2)) python3 -I -c "$PY_PGSSL" "$h" "$p" "$OPT_TIMEOUT" 2>/dev/null)
  case $r in
    SSL)   pass "server offers TLS (sslmode=$mode)" ;;
    NOSSL) if [[ $mode == require || $mode == verify-* ]]; then
             fail "server does not offer TLS, but DB_SSLMODE=$mode" "Set ssl = on in postgresql.conf with a certificate, or lower sslmode" "$DOC_DB"
           else warn "server does not offer TLS, so connections will be unencrypted" "Enable ssl = on in postgresql.conf if policy requires encryption in transit" "$DOC_DB"; fi ;;
    OTHER) warn "unexpected reply. Is $h:$p PostgreSQL?" "Check DB_HOST / DB_PORT" "$DOC_DB" ;;
    *)     skip "could not connect (${r:-no output}); see the connection check above" ;;
  esac
}

pgpass_esc() { local s=${1//\\/\\\\}; printf '%s' "${s//:/\\:}"; }

chk_pg_login() {
  local psql; psql=$(find_pg_bin psql)
  [[ -n $psql ]] || { skip "psql not installed, so the login test was skipped" "dnf install -y postgresql   (client only)"; return; }
  [[ -n $(get DB_PASSWORD) ]] || { skip "no DB_PASSWORD supplied, so the login test was skipped"; return; }
  local h p db u mode pf out rc
  h=$(get DB_HOST) p=$(get DB_PORT 5432) db=$(get DB_NAME mattermost) u=$(get DB_USER mmuser) mode=$(get DB_SSLMODE prefer)
  pf="$TMPD/pgpass"
  printf '%s:%s:%s:%s:%s\n' "$(pgpass_esc "$h")" "$p" "$(pgpass_esc "$db")" "$(pgpass_esc "$u")" "$(pgpass_esc "$(get DB_PASSWORD)")" > "$pf"
  chmod 600 "$pf"
  local sql="SELECT current_setting('server_version_num')||'|'||current_setting('server_version')||'|'||pg_encoding_to_char(d.encoding)||'|'||has_schema_privilege('public','CREATE')||'|'||current_setting('max_connections') FROM pg_database d WHERE d.datname=current_database();"
  out=$(PGPASSFILE=$pf PGHOST=$h PGPORT=$p PGDATABASE=$db PGUSER=$u PGSSLMODE=$mode PGCONNECT_TIMEOUT=$OPT_TIMEOUT \
        timeout $((OPT_TIMEOUT + 10)) "$psql" -X -w -A -t -c "$sql" 2>&1); rc=$?
  rm -f "$pf"
  if ((rc != 0)); then
    local fix="Check the connection details"
    case $out in
      *"password authentication failed"*) fix="Check DB_USER / DB_PASSWORD" ;;
      *"no pg_hba.conf entry"*)           fix="Add a pg_hba.conf rule on $h for this server's IP, then reload PostgreSQL" ;;
      *"does not exist"*)                 fix="Create the database and user as described in the docs" ;;
      *SSL*|*ssl*)                        fix="Check DB_SSLMODE against the server's TLS setup" ;;
    esac
    fail "login failed: $(oneline "$out" 90)" "$fix" "$DOC_DB"; return
  fi
  local vnum ver enc cre maxc min issues=()
  IFS='|' read -r vnum ver enc cre maxc <<< "$(head -1 <<< "$out")"
  min=$(get PG_MIN_VERSION 15)
  (( ${vnum:-0} < min * 10000 )) && issues+=("PostgreSQL $ver is older than $min")
  [[ $enc != UTF8 ]] && issues+=("encoding is $enc, not UTF8")
  [[ $cre != t && $cre != true ]] && issues+=("$u cannot CREATE in schema public")
  if ((${#issues[@]})); then
    fail "$(IFS=';'; echo "${issues[*]}")" \
      "PostgreSQL $min+, UTF8 database, and on PG15+: GRANT ALL ON SCHEMA public TO $u (or make $u the database owner)" "$DOC_DB"
  else
    pass "logged in · PostgreSQL $ver · UTF8 · max_connections $maxc"
  fi
}

# ── File storage ────────────────────────────────────────────────────────────
chk_store_write() {
  local dir=$1 user=mattermost t p=$1 how rc
  while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
  t="$p/.mm-preflight-$$-$RANDOM"
  local script='printf "mm-preflight\n" > "$1" && sync "$1" 2>/dev/null; grep -q mm-preflight "$1" && rm -f "$1"'
  if id "$user" >/dev/null 2>&1 && ((IS_ROOT)); then
    runuser -u "$user" -- bash -c "$script" _ "$t" 2>/dev/null; rc=$?; how="as $user"
  else
    bash -c "$script" _ "$t" 2>/dev/null; rc=$?; how="as $(id -un)"
  fi
  if ((rc == 0)) && [[ ! -e $t ]]; then
    local extra=""; [[ $p != "$dir" ]] && extra=" ($dir will be created under $p)"
    id "$user" >/dev/null 2>&1 || extra+=" · mattermost user not created yet: keep its UID/GID identical on every node"
    pass "write · read · delete OK $how$extra"
  else
    rm -f "$t" 2>/dev/null
    fail "cannot write to $p $how" "chown -R mattermost:mattermost $dir. On NFS, check the root_squash/anon settings and that UID/GID match the export" "$DOC_FILES"
  fi
}

chk_nfs_mount() {
  local dir=$1 p=$1 line src fs opts
  while [[ ! -e $p && $p != / ]]; do p=$(dirname "$p"); done
  line=$(findmnt -n -T "$p" -o SOURCE,FSTYPE,OPTIONS 2>/dev/null | head -1)
  read -r src fs opts <<< "$line"
  NFS_SRC=$src
  if [[ $fs != nfs* ]]; then
    fail "$p is on ${fs:-unknown} ($src), not NFS" \
         "Mount the shared export at $dir on every app node, e.g. fstab: server:/export $dir nfs4 defaults,_netdev,hard 0 0" "$DOC_FILES"
  elif [[ ,$opts, == *,soft,* ]]; then
    warn "$src ($fs) mounted with 'soft'" "Use 'hard' mounts so I/O errors don't corrupt files" "$DOC_FILES"
  else
    local v; v=$(grep -o 'vers=[0-9.]*' <<< "$opts")
    pass "$src · $fs${v:+ · $v}"
  fi
}

chk_nfs_server() {
  [[ ${NFS_SRC:-} == *:* ]] || { skip "no NFS source detected"; return; }
  local h=${NFS_SRC%%:*}; h=${h#[}; h=${h%]}
  chk_tcp "$h" 2049 "NFS" 0 "$DOC_FILES"
  [[ $S_STATUS == PASS ]] && S_DETAIL="$h:2049 open · ${TP_MS} ms"
}

chk_s3() {
  needs_py || return
  [[ -n $(get S3_ACCESS_KEY) && -n $(get S3_SECRET_KEY) ]] || { skip "no access keys supplied, so the write test was skipped"; return; }
  local r
  r=$(MMPF_S3_ENDPOINT=$(get S3_ENDPOINT) MMPF_S3_BUCKET=$(get S3_BUCKET) MMPF_S3_REGION=$(get S3_REGION us-east-1) \
      MMPF_S3_AK=$(get S3_ACCESS_KEY) MMPF_S3_SK=$(get S3_SECRET_KEY) MMPF_S3_PATH=$(get S3_PATH_STYLE no) \
      MMPF_S3_KEY="mm-preflight/${HOST_SHORT}-${STAMP}.txt" MMPF_TIMEOUT=$((OPT_TIMEOUT * 2)) \
      timeout $((OPT_TIMEOUT * 8)) python3 -I -c "$PY_S3" 2>&1 | tail -1)
  if [[ $r == OK ]]; then pass "PUT · GET · DELETE succeeded in $(get S3_BUCKET)"; return; fi
  local step code ecode msg fix
  read -r _ step code ecode msg <<< "$r"
  case $ecode in
    AccessDenied)          fix="Grant s3:PutObject, s3:GetObject, s3:DeleteObject on arn:aws:s3:::$(get S3_BUCKET)/* and s3:ListBucket on the bucket" ;;
    NoSuchBucket)          fix="Create bucket $(get S3_BUCKET), or fix S3_BUCKET" ;;
    SignatureDoesNotMatch) fix="Check the secret key, S3_REGION and S3_PATH_STYLE (MinIO usually needs path-style)" ;;
    InvalidAccessKeyId)    fix="Check S3_ACCESS_KEY" ;;
    PermanentRedirect|AuthorizationHeaderMalformed) fix="The bucket is in a different region. Set S3_REGION and S3_ENDPOINT to match" ;;
    Connection)            fix="Check TLS trust (update-ca-trust for internal CAs), DNS and the endpoint URL" ;;
    *)                     fix="Check the endpoint, bucket and credentials" ;;
  esac
  fail "$step failed: ${ecode:-error} ${code:+(HTTP $code)} $(oneline "${msg:-}" 60)" "$fix" "$DOC_FILES"
}

# ── Email, directory, search, cache ─────────────────────────────────────────
chk_smtp_banner() {
  local h=$1 p=$2 sec=$3 out
  if [[ $sec == tls ]]; then
    out=$(printf 'QUIT\r\n' | timeout $((OPT_TIMEOUT + 5)) openssl s_client -quiet -connect "$h:$p" -servername "$h" 2>/dev/null | head -1)
  else
    out=$(timeout "$OPT_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2" || exit 1; IFS= read -r -t "$3" l <&3; printf "QUIT\r\n" >&3; printf "%s" "$l"' \
          _ "$h" "$p" "$OPT_TIMEOUT" 2>/dev/null)
  fi
  out=${out%$'\r'}
  if [[ $out == 220* ]]; then pass "$(trunc "$out" 60)"
  elif [[ -z $out ]]; then fail "no SMTP greeting from $h:$p" "Check port and security (587 STARTTLS · 465 TLS · 25 plain)" "$DOC_NETWORK"
  else fail "unexpected greeting: $(oneline "$out" 60)" "Confirm $h:$p is an SMTP relay" "$DOC_NETWORK"; fi
}

chk_ldap_bind() {
  have ldapsearch || { skip "ldapsearch not installed, so the bind test was skipped" "dnf install -y openldap-clients"; return; }
  local sec h p uri pwf out rc
  sec=$(get LDAP_SECURITY ldaps) h=$(get LDAP_HOST) p=$(get LDAP_PORT 636)
  local -a extra=()
  if [[ $sec == ldaps ]]; then uri="ldaps://$h:$p"; else uri="ldap://$h:$p"; fi
  [[ $sec == starttls ]] && extra+=(-ZZ)
  pwf="$TMPD/ldap.pw"; printf '%s' "$(get LDAP_BIND_PASSWORD)" > "$pwf"; chmod 600 "$pwf"
  out=$(timeout $((OPT_TIMEOUT + 10)) ldapsearch -x -LLL "${extra[@]}" -o nettimeout="$OPT_TIMEOUT" -H "$uri" \
        -D "$(get LDAP_BIND_DN)" -y "$pwf" -b "$(get LDAP_BASE_DN)" -s base '(objectClass=*)' dn 2>&1); rc=$?
  rm -f "$pwf"
  case $rc in
    0)  pass "bind succeeded${ANS[LDAP_BASE_DN]:+ · base DN found}" ;;
    49) fail "invalid credentials" "Check LDAP_BIND_DN / LDAP_BIND_PASSWORD (AD sub-code in: $(oneline "$out" 60))" "$DOC_NETWORK" ;;
    32) fail "base DN not found" "Check LDAP_BASE_DN" "$DOC_NETWORK" ;;
    *)  fail "ldapsearch exit $rc: $(oneline "$out" 80)" "Check host, port, security mode and CA trust" "$DOC_NETWORK" ;;
  esac
}

chk_ldap_cleartext() {
  local what="user passwords at login"; [[ -n $(get LDAP_BIND_DN) ]] && what="the bind password (including this test's) and $what"
  warn "LDAP_SECURITY=none, so $what cross the network unencrypted" \
       "Use LDAPS (port 636) or StartTLS (port 389) in Mattermost's AD/LDAP settings, then set LDAP_SECURITY to match" "$DOC_NETWORK"
}

chk_redis() {
  local h=$1 p=$2 r
  r=$(timeout "$OPT_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2" || exit 1; printf "PING\r\n" >&3; IFS= read -r -t 3 l <&3; printf "%s" "$l"' _ "$h" "$p" 2>/dev/null)
  r=${r%$'\r'}
  case $r in
    +PONG)    pass "PONG" ;;
    -NOAUTH*) pass "reachable · authentication required" ;;
    "")       tcp_probe "$h" "$p"
              if ((TP_RC == 0)); then warn "connected, but no reply to PING (TLS-only Redis?)" "Confirm the Redis TLS settings match" "$DOC_REDIS"
              else tcp_result "$h" "$p" "Redis" 0 "$DOC_REDIS"; fi ;;
    *)        warn "unexpected reply: $(oneline "$r" 50)" "Confirm $h:$p is Redis" "$DOC_REDIS" ;;
  esac
}

chk_search() {
  local url=$1 body="$TMPD/search.json" ver dist
  url_parse "$url"
  http_get "$url" "$body" "$(get SEARCH_USER)" "$(get SEARCH_PASSWORD)"
  if ((H_RC != 0)); then http_result "$url" 0 "$DOC_SEARCH"; return; fi
  case $H_CODE in
    200) ver=$(grep -o '"number"[[:space:]]*:[[:space:]]*"[^"]*"' "$body" | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
         dist=$(grep -q '"distribution"[[:space:]]*:[[:space:]]*"opensearch"' "$body" && echo OpenSearch || echo Elasticsearch)
         if [[ $dist == Elasticsearch && -n $ver && ${ver%%.*} -lt 8 ]]; then
           warn "Elasticsearch $ver found; v8 or v9 is required" "Upgrade the search cluster" "$DOC_SEARCH"
         else pass "$dist ${ver:-?} responding"; fi ;;
    401|403) warn "reachable, but HTTP $H_CODE" "Supply SEARCH_USER / SEARCH_PASSWORD to verify the credentials Mattermost will use" "$DOC_SEARCH" ;;
    *) warn "HTTP $H_CODE from $url" "Check the URL points at the cluster's HTTP endpoint" "$DOC_SEARCH" ;;
  esac
  rm -f "$body"
}

chk_rtcd_api() {
  local h=$1 p=$2 body="$TMPD/rtcd.json"
  tcp_probe "$h" "$p"
  if ((TP_RC != 0)); then tcp_result "$h" "$p" "rtcd" 1 "$DOC_RTCD"; return; fi
  url_parse "http://$h:$p/version"
  http_get "http://$h:$p/version" "$body"
  if [[ $H_RC == 0 && $H_CODE == 200 ]] && grep -q '{' "$body"; then
    pass "rtcd responding · $(oneline "$(tr -d '{}"' < "$body")" 50)"
  else
    warn "port open, but /version did not answer like rtcd (HTTP ${H_CODE:-?})" "Confirm rtcd is the service listening on $p" "$DOC_RTCD"
  fi
  rm -f "$body"
}

# ── PostgreSQL server (db role) ─────────────────────────────────────────────
PG_PRESENT=0 PG_SETTINGS="" PG_SETTINGS_RC=99 PG_HBA_FILE="" PG_DATA_DIR=""

pg_local() {
  local psql; psql=$(find_pg_bin psql)
  [[ -n $psql ]] && ((IS_ROOT)) && id postgres >/dev/null 2>&1 || return 2
  (cd / && timeout 15 runuser -u postgres -- "$psql" -X -A -t -p "$(get DB_PORT 5432)" -c "$1" 2>&1)
}

pg_fetch_settings() {
  ((PG_SETTINGS_RC != 99)) && return
  PG_SETTINGS=$(pg_local "SELECT current_setting('server_version')||'|'||current_setting('max_connections')||'|'||current_setting('ssl')||'|'||current_setting('password_encryption')||'|'||current_setting('data_directory')||'|'||current_setting('hba_file')")
  PG_SETTINGS_RC=$?
  if ((PG_SETTINGS_RC == 0)); then
    local a b c d; IFS='|' read -r a b c d PG_DATA_DIR PG_HBA_FILE <<< "$PG_SETTINGS"
  fi
}

pg_skip_reason() {
  if ((!PG_PRESENT)); then skip "PostgreSQL not installed yet"
  elif ((!IS_ROOT)); then skip "run as root to inspect the local server" "sudo ./$SELF"
  elif ((PG_SETTINGS_RC == 2)); then skip "psql client not found on this server" "dnf install -y postgresql"
  else skip "could not query the local server: $(oneline "$PG_SETTINGS" 70)"; fi
}

chk_pg_installed() {
  local min=$1 bin ver major
  bin=$(find_pg_bin postgres)
  if [[ -z $bin ]]; then
    PG_PRESENT=0
    warn "PostgreSQL server not installed yet" "Install PostgreSQL $min or newer (RHEL AppStream module or the PGDG repo), then re-run" "$DOC_DB"; return
  fi
  PG_PRESENT=1
  ver=$("$bin" --version 2>/dev/null | awk '{print $NF}'); major=${ver%%.*}
  if [[ $major =~ ^[0-9]+$ ]] && (( major >= min )); then pass "PostgreSQL $ver"
  else fail "PostgreSQL $ver found; Mattermost needs $min or newer" "Upgrade PostgreSQL" "$DOC_REQS"; fi
}

chk_pg_service() {
  ((PG_PRESENT)) || { skip "PostgreSQL not installed yet"; return; }
  local u; u=$(systemctl list-units --type=service --state=running --no-legend 'postgresql*' 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -n $u ]]; then pass "$u running"
  else fail "no postgresql service running" "postgresql-setup --initdb (first time) && systemctl enable --now postgresql" "$DOC_DB"; fi
}

chk_pg_listen() {
  ((PG_PRESENT)) || { skip "PostgreSQL not installed yet"; return; }
  local p=$1 out
  have ss || { skip "ss not installed (dnf install -y iproute)"; return; }
  out=$(ss -H -ltn "sport = :$p" 2>/dev/null | awk '{print $4}')
  if [[ -z $out ]]; then fail "nothing listening on $p" "Start PostgreSQL and check 'port' in postgresql.conf" "$DOC_DB"; return; fi
  if grep -qvE '^(127\.|\[::1\])' <<< "$out"; then pass "listening on $(paste -sd' ' - <<< "$out")"
  else fail "listening on loopback only ($(paste -sd' ' - <<< "$out"))" \
            "Set listen_addresses = '*' (or this server's IP) in postgresql.conf and restart" "$DOC_DB"; fi
}

chk_pg_settings() {
  ((PG_PRESENT)) || { skip "PostgreSQL not installed yet"; return; }
  pg_fetch_settings
  ((PG_SETTINGS_RC == 0)) || { pg_skip_reason; return; }
  local ver maxc ssl penc; IFS='|' read -r ver maxc ssl penc _ _ <<< "$PG_SETTINGS"
  if [[ $penc != scram-sha-256 ]]; then
    warn "v$ver · ssl $ssl · password_encryption $penc" "Use password_encryption = scram-sha-256 and scram-sha-256 rules in pg_hba.conf" "$DOC_DB"
  else pass "v$ver · ssl $ssl · scram-sha-256"; fi
}

chk_pg_conns() {
  ((PG_PRESENT)) || { skip "PostgreSQL not installed yet"; return; }
  pg_fetch_settings
  ((PG_SETTINGS_RC == 0)) || { pg_skip_reason; return; }
  local maxc nodes need; IFS='|' read -r _ maxc _ _ _ _ <<< "$PG_SETTINGS"
  local -a an; split_list an "$(get APP_NODES)"; nodes=${#an[@]}; ((nodes < 1)) && nodes=1
  need=$(( $(get MAX_OPEN_CONNS 300) * nodes + 20 ))
  if (( maxc >= need )); then pass "max_connections $maxc (≥ $need for $nodes app node(s))"
  else warn "max_connections is $maxc, but $nodes app node(s) × MaxOpenConns $(get MAX_OPEN_CONNS 300) needs ~$need" \
            "Raise max_connections in postgresql.conf (and memory to match), or use PgBouncer" "$DOC_DB"; fi
}

chk_pg_objects() {
  ((PG_PRESENT)) || { skip "PostgreSQL not installed yet"; return; }
  pg_fetch_settings
  ((PG_SETTINGS_RC == 0)) || { pg_skip_reason; return; }
  local db=$1 u=$2 out d r enc
  out=$(pg_local "SELECT (SELECT count(*) FROM pg_database WHERE datname='$db')||'|'||(SELECT count(*) FROM pg_roles WHERE rolname='$u')||'|'||coalesce((SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='$db'),'')")
  IFS='|' read -r d r enc <<< "$out"
  if [[ $d == 1 && $r == 1 ]]; then
    if [[ $enc == UTF8 ]]; then pass "database '$db' (UTF8) and role '$u' exist"
    else fail "database '$db' uses $enc encoding" "Recreate it: CREATE DATABASE $db WITH ENCODING 'UTF8' TEMPLATE template0;" "$DOC_DB"; fi
  else
    warn "$([[ $d != 1 ]] && echo "database '$db' missing")$([[ $d != 1 && $r != 1 ]] && echo ', ')$([[ $r != 1 ]] && echo "role '$u' missing")" \
         "CREATE DATABASE $db; CREATE USER $u WITH PASSWORD '…'; GRANT ALL PRIVILEGES ON DATABASE $db TO $u; ALTER DATABASE $db OWNER TO $u;" "$DOC_DB"
  fi
}

hba_match() {  # file ip db user → "lineno|rule|method"
  awk -v ip="$2" -v db="$3" -v usr="$4" '
    function ip2n(s,  a) { if (split(s, a, ".") != 4) return -1; return ((a[1]*256 + a[2])*256 + a[3])*256 + a[4] }
    function inlist(v, l,  a, n, i) { n = split(l, a, ","); for (i = 1; i <= n; i++) if (a[i] == v || a[i] == "all") return 1; return 0 }
    function bits(m,  a, i, b, o) { split(m, a, "."); b = 0; for (i = 1; i <= 4; i++) { o = a[i] + 0; while (o > 0) { b += o % 2; o = int(o / 2) } } return b }
    function cidr(ipn, net, nb,  nn, d) { nn = ip2n(net); if (nn < 0) return 0; d = 2 ^ (32 - nb); return int(ipn / d) == int(nn / d) }
    BEGIN { ipn = ip2n(ip) }
    { sub(/#.*/, ""); if (NF < 4) next }
    $1 ~ /^host(ssl|nossl|gssenc|nogssenc)?$/ {
      if (!(inlist(db, $2) || ($2 == "sameuser" && db == usr))) next
      if (!inlist(usr, $3) && $3 !~ /^\+/) next
      addr = $4; meth = $5; ok = 0
      if (addr == "all" || addr == "0.0.0.0/0") ok = 1
      else if (addr ~ /^[0-9.]+\/[0-9]+$/) { split(addr, c, "/"); ok = cidr(ipn, c[1], c[2]) }
      else if (addr ~ /^[0-9.]+$/ && $5 ~ /^[0-9.]+$/) { ok = cidr(ipn, addr, bits($5)); meth = $6 }
      if (ok) { print NR "|" $1 " " $2 " " $3 " " addr "|" meth; exit }
    }' "$1"
}

chk_pg_hba() {
  local node=$1 ip m line rule meth db u
  ((PG_PRESENT)) || { skip "PostgreSQL not installed yet"; return; }
  pg_fetch_settings
  ((PG_SETTINGS_RC == 0)) || { pg_skip_reason; return; }
  [[ -r $PG_HBA_FILE ]] || { skip "cannot read $PG_HBA_FILE"; return; }
  ip=$(resolve4 "$node" | head -1)
  [[ -n $ip ]] || { fail "$node does not resolve" "Fix DNS for $node" "$DOC_DB"; return; }
  db=$(get DB_NAME mattermost) u=$(get DB_USER mmuser)
  m=$(hba_match "$PG_HBA_FILE" "$ip" "$db" "$u")
  if [[ -z $m ]]; then
    fail "no rule matches $ip for $db/$u" \
      "Add to $PG_HBA_FILE:  host  $db  $u  $ip/32  scram-sha-256   then: systemctl reload postgresql   (rules using hostnames, samenet or IPv6 aren't evaluated here)" "$DOC_DB"
    return
  fi
  IFS='|' read -r line rule meth <<< "$m"
  case $meth in
    reject)   fail "line $line rejects $ip" "Place an allow rule above line $line" "$DOC_DB" ;;
    trust)    warn "line $line uses trust, so no password is required" "Use scram-sha-256 instead of trust" "$DOC_DB" ;;
    password) warn "line $line: cleartext password" "Use scram-sha-256" "$DOC_DB" ;;
    *)        pass "$ip allowed · line $line · $meth" ;;
  esac
}

chk_pg_space() {
  local min=$1
  pg_fetch_settings
  if ((PG_SETTINGS_RC == 0)) && [[ -n $PG_DATA_DIR ]]; then chk_disk "$PG_DATA_DIR" "$min"
  else chk_disk /var/lib/pgsql "$min"; fi
}

# ── Proxy role ──────────────────────────────────────────────────────────────
chk_cert_file() {
  local cert=$1 host=$2 end n v
  [[ -r $cert ]] || { fail "cannot read $cert" "Check the path and permissions (run as root)" "$DOC_TLS"; return; }
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || { fail "$cert is not a PEM certificate" "Convert it: openssl x509 -inform der -in cert.cer -out cert.pem" "$DOC_TLS"; return; }
  end=$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)
  n=$(grep -c 'BEGIN CERTIFICATE' "$cert")
  if ! openssl x509 -in "$cert" -noout -checkend 0 >/dev/null 2>&1; then fail "expired ($end)" "Renew the certificate" "$DOC_TLS"; return; fi
  if [[ $(openssl x509 -in "$cert" -noout -checkhost "$host" 2>/dev/null) != *"does match"* ]]; then
    fail "does not cover $host" "Reissue the certificate with $host in the Subject Alternative Names" "$DOC_TLS"; return
  fi
  v=$(openssl verify -untrusted "$cert" "$cert" 2>&1)
  if [[ $(tail -1 <<< "$v") != *": OK" ]]; then
    local why; why=$(grep -m1 -o 'error [0-9]* at [0-9]* depth lookup: .*' <<< "$v" | sed 's/.*lookup: //')
    warn "covers $host, but the chain does not verify ($n cert(s) in file): ${why:-verification failed}" \
         "Append the intermediate certificates to the file (leaf first), or trust your internal root CA" "$DOC_TLS"; return
  fi
  if ! openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1; then warn "valid, but expires within 30 days ($end)" "Renew before $end" "$DOC_TLS"; return; fi
  pass "covers $host · chain OK · expires $(date -d "$end" +%Y-%m-%d 2>/dev/null || echo "$end")"
}

chk_key_match() {
  local cert=$1 key=$2 a b
  [[ -r $key ]] || { skip "cannot read $key (run as root)"; return; }
  a=$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)
  b=$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256 2>/dev/null)
  if [[ -n $a && $a == "$b" ]]; then pass "private key matches the certificate"
  else fail "private key does not match the certificate" "Pair the certificate with the key it was issued for" "$DOC_TLS"; fi
}

chk_nginx_conf() {
  have nginx || { info "nginx not installed yet"; return; }
  ((IS_ROOT)) || { skip "run as root to read the nginx configuration"; return; }
  local c; c=$(timeout 10 nginx -T 2>/dev/null)
  [[ -n $c ]] || { warn "nginx -T failed, so the configuration has errors" "Run 'nginx -t' to see them" "$DOC_NGINX"; return; }
  if ! grep -qE '8065|mattermost' <<< "$c"; then info "no Mattermost site configured yet" "" "$DOC_NGINX"; return; fi
  local -a miss=()
  grep -qiE 'proxy_set_header[[:space:]]+Upgrade' <<< "$c" || miss+=("WebSocket Upgrade header")
  grep -qiE 'client_max_body_size' <<< "$c" || miss+=("client_max_body_size")
  if ((${#miss[@]})); then warn "Mattermost site found, missing: ${miss[*]}" "Compare with the reference NGINX config in the docs" "$DOC_NGINX"
  else pass "Mattermost site with WebSocket upgrade and upload size set"; fi
}

# ── Offloader role ──────────────────────────────────────────────────────────
chk_docker() {
  have docker || { fail "Docker is not installed" "Install Docker Engine (docker-ce) from Docker's RHEL repository" "$DOC_OFFLOADER"; return; }
  if docker --version 2>/dev/null | grep -qi podman; then
    warn "'docker' is the podman shim" "calls-offloader is documented with Docker Engine; install docker-ce" "$DOC_OFFLOADER"; return
  fi
  local v rc; v=$(timeout 15 docker version --format '{{.Server.Version}}' 2>&1); rc=$?
  if ((rc == 0)); then pass "Docker Engine $v"
  else fail "Docker daemon not reachable: $(oneline "$v" 60)" "systemctl enable --now docker" "$DOC_OFFLOADER"; fi
}

chk_offloader_user() {
  local u=$1
  if ! id "$u" >/dev/null 2>&1; then
    warn "user $u not created yet" "useradd --system --user-group $u && usermod -a -G docker $u" "$DOC_OFFLOADER"; return
  fi
  if id -nG "$u" | tr ' ' '\n' | grep -qx docker; then pass "$u exists and is in the docker group"
  else fail "$u is not in the docker group" "usermod -a -G docker $u" "$DOC_OFFLOADER"; fi
}

chk_offloader_images() {
  have docker || { skip "Docker not installed"; return; }
  local imgs; imgs=$(timeout 15 docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^mattermost/calls-(recorder|transcriber):' | paste -sd, -)
  if [[ -n $imgs ]]; then pass "$imgs"
  elif is_yes "$(get AIR_GAPPED)"; then
    fail "no calls-recorder / calls-transcriber images loaded" "docker pull on a connected host, docker save, copy, docker load here (match your Calls plugin version)" "$DOC_AIRGAP"
  else info "not pulled yet. Docker pulls them from Docker Hub on the first job"; fi
}

chk_note() { info "$1" "" "${2:-}"; }

# ── Capacity vs Mattermost reference architectures ──────────────────────────
fmt_n() { printf '%s' "$1" | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta'; }
box_fits() {  # vcpu gib → true if this box has at least that
  local cpu kb; cpu=$(nproc 2>/dev/null || echo 0); kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  (( cpu >= $1 && kb >= $2 * 1048576 * 92 / 100 ))
}
box_desc() { printf '%s vCPU / %s GiB' "$(nproc)" "$(awk '/^MemTotal:/{printf "%.1f", $2/1048576}' /proc/meminfo)"; }
CAPACITY_LINE=""

# chk_capacity <component: app|db|search> <nodes-of-this-kind>
chk_capacity() {
  local comp=$1 have_n=$2 t users an av ag dv dg dr en ev eg need_n v g best="" best_line="" next_line=""
  local target; target=$(get TARGET_USERS)
  for t in "${REF_TIERS[@]}"; do
    read -r users an av ag dv dg dr en ev eg <<< "$t"
    case $comp in
      app)    need_n=$an v=$av g=$ag ;;
      db)     need_n=$((dr + 1)) v=$dv g=$dg ;;
      search) need_n=$en v=$ev g=$eg; ((en == 0)) && continue ;;
    esac
    local spec="$need_n × $v vCPU / $g GiB"
    if [[ $comp == db ]]; then
      if ((dr == 0)); then spec="single $v vCPU / $g GiB server"; else spec="writer + $dr reader(s), each $v vCPU / $g GiB"; fi
    fi
    if box_fits "$v" "$g" && (( have_n >= need_n )); then best=$users best_line=$spec
    elif [[ -z $next_line ]] && [[ -n $best || $users == 200 || ( $comp == search && $users == 2000 ) ]]; then
      next_line="$(fmt_n "$users") needs $spec"
    fi
  done
  local unit; case $comp in app) unit="app node(s)" ;; db) unit="database node(s)" ;; search) unit="search node(s)" ;; esac
  local here; here="this box: $(box_desc), $have_n $unit"
  # Target comparison takes priority when given
  if [[ -n $target ]]; then
    local tgt_line=""
    for t in "${REF_TIERS[@]}"; do
      read -r users an av ag dv dg dr en ev eg <<< "$t"
      (( users >= target )) || continue
      case $comp in
        app) tgt_line="$an × $av vCPU / $ag GiB app nodes" ;;
        db)  tgt_line="writer + $dr reader(s), each $dv vCPU / $dg GiB" ;;
        search) tgt_line="$en × $ev vCPU / $eg GiB search nodes" ;;
      esac
      break
    done
    if [[ -z $tgt_line ]]; then
      info "$(fmt_n "$target") users is beyond the published reference architectures (largest: 100,000)" \
           "Size with Mattermost and validate with the load-test tool (mattermost-load-test-ng)" "$DOC_SCALE"
    elif [[ -n $best ]] && (( best >= target )); then
      pass "meets the $(fmt_n "$users")-user reference tier for your $(fmt_n "$target") target ($here)"
    else
      warn "your $(fmt_n "$target")-user target maps to the $(fmt_n "$users") tier: $tgt_line ($here)" \
           "Add CPU / memory or nodes to match the reference architecture, or validate a smaller design with a load test" "$DOC_SCALE"
    fi
    case $S_STATUS in
      PASS) CAPACITY_LINE="Meets the reference tier for $(fmt_n "$target") concurrent users" ;;
      WARN) CAPACITY_LINE="Under-sized for $(fmt_n "$target") concurrent users (reference tier)" ;;
      *)    CAPACITY_LINE="$(fmt_n "$target") users is beyond the published reference tiers" ;;
    esac
    return
  fi
  if [[ -n $best ]]; then
    pass "up to ~$(fmt_n "$best") concurrent users (reference tier: $best_line)${next_line:+ · next tier $next_line}"
    CAPACITY_LINE="Sized for ~$(fmt_n "$best") concurrent users (Mattermost reference tier)"
  else
    warn "below the smallest published $comp spec ($here)" "${next_line:+Smallest tier: $next_line}" "$DOC_SCALE"
    CAPACITY_LINE="Below the smallest Mattermost reference tier"
  fi
  if [[ $comp == app && $have_n == 1 ]]; then
    S_DETAIL+=" · single-server team guidance: "
    if box_fits 2 4; then S_DETAIL+="up to 2,000 registered users"
    elif box_fits 1 2; then S_DETAIL+="up to 1,000 registered users"
    else S_DETAIL+="below 1 vCPU / 2 GB"; fi
  fi
  S_DOC=$DOC_SCALE
}

chk_capacity_proxy() {
  if box_fits 16 64; then pass "matches the 16 vCPU / 64 GiB proxy used in every reference tier"
  else info "reference tiers were tested with a 16 vCPU / 64 GiB proxy ($(box_desc) here); Mattermost notes this is overspecified for small deployments" "" "$DOC_SCALE"; fi
}

# ── Latency & bandwidth ─────────────────────────────────────────────────────
chk_latency() {  # host port
  local h=$1 p=$2 r mn avg mx jit lost tot warn_ms fail_ms
  needs_py || return
  warn_ms=$(get LATENCY_WARN_MS 5) fail_ms=$(get LATENCY_FAIL_MS 30)
  r=$(timeout $(( OPT_TIMEOUT * 4 + 10 )) python3 -I -c "$PY_RTT" "$h" "$p" 10 "$(( OPT_TIMEOUT < 2 ? OPT_TIMEOUT : 2 ))" 2>/dev/null)
  case $r in
    OK*) read -r _ mn avg mx jit lost tot _ <<< "$r"
         local d="avg ${avg} ms · min ${mn} · max ${mx} · jitter ${jit} ms"
         (( lost > 0 )) && d+=" · $lost/$tot lost"
         if awk -v a="$avg" -v f="$fail_ms" 'BEGIN{exit !(a > f)}'; then
           fail "$d" "Round trip is above ${fail_ms} ms. Keep Mattermost, its database and cluster peers on the same site or low-latency network" "$DOC_SCALE"
         elif awk -v a="$avg" -v w="$warn_ms" 'BEGIN{exit !(a > w)}' || (( lost > 0 )); then
           warn "$d" "Above the ${warn_ms} ms target, or packets were lost. Check routing, any firewall that inspects traffic, and that both hosts share a site" "$DOC_SCALE"
         else pass "$d"; fi ;;
    DNS)  fail "$h does not resolve" "Fix DNS for $h" ;;
    NONE*) warn "no TCP response on $p (${r#NONE }), so latency was not measured" "Measure against an open port, or run on $h:  sudo ./$SELF --listen tcp:$p" ;;
    *)    warn "latency probe inconclusive: ${r:-no output}" ;;
  esac
}

chk_bandwidth() {  # host port
  local h=$1 p=$2 r up down min mb
  needs_py || return
  min=$(get BANDWIDTH_WARN_MBPS 500) mb=$(get PERF_MB 64)
  r=$(timeout 300 python3 -I -c "$PY_PERF" "$h" "$p" "$mb" "$OPT_TIMEOUT" 2>/dev/null)
  case $r in
    OK*) read -r _ up down <<< "$r"
         local d; d="up $(fmt_n "$up") Mbit/s · down $(fmt_n "$down") Mbit/s (${mb} MB each way)"
         if (( up < min || down < min )); then
           warn "$d" "Below ${min} Mbit/s. Check NIC speed and duplex, VM network limits, and any inspection device in the path" "$DOC_SCALE"
         else pass "$d"; fi ;;
    NOLISTENER) skip "no bandwidth listener on $h:$p" "Run on $h:  sudo ./$SELF --listen perf:$p   then re-run" ;;
    PROTO)      skip "$h:$p is not a bandwidth listener" "Run on $h:  sudo ./$SELF --listen perf:$p" ;;
    TIMEOUT)    warn "connection to $h:$p timed out" "Allow TCP $p to $h for the test, or skip PERF_TEST" ;;
    *)          warn "bandwidth test failed: ${r:-no output}" "Re-run, or check firewalls between the hosts" ;;
  esac
}

# Add latency (+ optional bandwidth) checks for a list of "label|host|port" targets
plan_perf() {
  local -a targets=("$@"); local t label h p seen=" "
  ((${#targets[@]})) || return 0
  for t in "${targets[@]}"; do
    IFS='|' read -r label h p <<< "$t"
    [[ -z $h ]] && continue
    add "Network performance" "Latency to $label" chk_latency "$h" "$p"
  done
  if is_yes "$(get PERF_TEST)"; then
    for t in "${targets[@]}"; do
      IFS='|' read -r label h p <<< "$t"
      [[ -z $h || $seen == *" $h "* ]] && continue
      seen+="$h "
      add "Network performance" "Bandwidth to $h" chk_bandwidth "$h" "$(get PERF_PORT 18999)"
    done
  fi
}

# ════════════════════════════════════════════════════════════════════════════
#  Plans
# ════════════════════════════════════════════════════════════════════════════
P_SEC=() P_LABEL=() P_CMD=()
INTERNAL_HTTP=()
add() { P_SEC+=("$1"); P_LABEL+=("$2"); shift 2; local IFS=$'\x1f'; P_CMD+=("$*"); }

plan_inbound() {  # port proto service expect who doc
  add "Inbound ports" "$3 · $1/$2 free" chk_listen "$1" "$2" "$3" "$4" "$6"
  add "Inbound ports" "Firewall · $1/$2" chk_fw "$1" "$2" "$5" "$6"
}

plan_system() {
  local r=$ROLE dp
  dp=$(get DISK_PATH "${DEF_DISK_PATH[$r]}")
  add System "Operating system"   chk_os
  add System "CPU architecture"   chk_arch
  add System "CPU"                chk_cpu "$(get MIN_CPU "${DEF_CPU[$r]}")"
  add System "Memory"             chk_ram "$(get MIN_RAM_GB "${DEF_RAM[$r]}")"
  add System "Free space"         chk_disk "$dp" "$(get MIN_DISK_GB "${DEF_DISK[$r]}")"
  add System "Time sync (NTP)"    chk_ntp
  add System "Hostname resolves"  chk_self_dns
  add System "SELinux"            chk_selinux
  add System "Host firewall"      chk_firewalld_state
  add System "SSH access"         chk_ssh "$(get SSH_PORT 22)"
  add System "Open-file limits"   chk_nofile 65536
  add System "Privileges"         chk_root
  add System "Required tools"     chk_tools_required
  add System "Optional tools"     chk_tools_optional
}

plan_outbound_proxy() {
  local px; px=$(get OUTBOUND_PROXY)
  [[ -z $px ]] && return
  url_parse "$px"
  add "Outbound proxy" "Reach $U_HOST:$U_PORT" chk_tcp "$U_HOST" "$U_PORT" "the proxy" 0 "$DOC_NETWORK"
  add "Outbound proxy" "NO_PROXY coverage" chk_noproxy "${INTERNAL_HTTP[*]:-}"
}

plan_app() {
  local -a peers reps rtcds perf=(); local x
  split_list peers "$(get APP_PEERS)"
  add Capacity "App node sizing" chk_capacity app $(( ${#peers[@]} + 1 ))

  plan_inbound 8065 tcp "Mattermost" mattermost "the proxy / load balancer" "$DOC_NETWORK"
  plan_inbound 8067 tcp "Metrics" mattermost "Prometheus" "$DOC_NETWORK"
  if ((${#peers[@]})); then
    plan_inbound 8074 tcp "Cluster" mattermost "the other app nodes" "$DOC_HA"
    plan_inbound 8074 udp "Cluster" mattermost "the other app nodes" "$DOC_HA"
  fi
  if [[ $(get CALLS_MODE) == integrated ]]; then
    local rp; rp=$(get RTC_PORT 8443)
    plan_inbound "$rp" udp "Calls" mattermost "Calls clients" "$DOC_CALLS"
    plan_inbound "$rp" tcp "Calls" mattermost "Calls clients" "$DOC_CALLS"
  fi

  local dh dp; dh=$(get DB_HOST) dp=$(get DB_PORT 5432)
  add Database "Resolve $dh"        chk_dns "$dh" "$DOC_DB"
  add Database "Connect $dh:$dp"    chk_tcp "$dh" "$dp" "PostgreSQL" 0 "$DOC_DB"
  add Database "TLS support"        chk_pg_ssl "$dh" "$dp" "$(get DB_SSLMODE prefer)"
  add Database "Login & privileges" chk_pg_login
  split_list reps "$(get DB_REPLICAS)"
  for x in "${reps[@]}"; do hp_split "$x" 5432; add Database "Replica $HP_HOST:$HP_PORT" chk_tcp "$HP_HOST" "$HP_PORT" "PostgreSQL" 0 "$DOC_DB"; done
  perf+=("database|$dh|$dp")
  for x in "${reps[@]}"; do hp_split "$x" 5432; perf+=("replica $HP_HOST|$HP_HOST|$HP_PORT"); done
  for x in "${peers[@]}"; do perf+=("peer ${x%%:*}|${x%%:*}|8074"); done

  local dir; dir=$(get DATA_DIR /opt/mattermost/data)
  case $(get FILE_STORE local) in
    local)
      add "File storage" "Data directory writable" chk_store_write "$dir"
      add "File storage" "Data directory space"    chk_disk "$dir" "$(get MIN_DISK_GB 20)" ;;
    nfs)
      add "File storage" "NFS mount"               chk_nfs_mount "$dir"
      local nsrc; nsrc=$(findmnt -n -T "$dir" -o SOURCE 2>/dev/null | head -1)
      [[ $nsrc == *:* ]] && perf+=("NFS ${nsrc%%:*}|${nsrc%%:*}|2049")
      add "File storage" "NFS server reachable"    chk_nfs_server
      add "File storage" "Write test"              chk_store_write "$dir"
      add "File storage" "Space on share"          chk_disk "$dir" "$(get MIN_DISK_GB 20)" ;;
    s3)
      url_parse "$(get S3_ENDPOINT)"
      local sh=$U_HOST sp=$U_PORT ss=$U_SCHEME
      is_yes "$(get S3_PATH_STYLE)" || sh="$(get S3_BUCKET).$U_HOST"
      INTERNAL_HTTP+=("$U_HOST")
      add "File storage" "Resolve $sh"             chk_dns "$sh" "$DOC_FILES"
      add "File storage" "Connect $sh:$sp"         chk_tcp "$sh" "$sp" "S3" 0 "$DOC_FILES"
      [[ $ss == https ]] && add "File storage" "TLS certificate" chk_tls "$sh" "$sp" "" "$sh" fail "$DOC_FILES"
      add "File storage" "Write · read · delete"   chk_s3 ;;
  esac

  if ((${#peers[@]})); then
    for x in "${peers[@]}"; do
      x=${x%%:*}
      add Cluster "Resolve $x"         chk_dns "$x" "$DOC_HA"
      add Cluster "Gossip TCP to $x"    chk_tcp "$x" 8074 "Mattermost" 1 "$DOC_HA"
      add Cluster "Gossip UDP to $x"    chk_udp "$x" 8074 "Mattermost" "$DOC_HA"
    done
  fi

  if [[ -n $(get SMTP_HOST) ]]; then
    local mh mp ms; mh=$(get SMTP_HOST) mp=$(get SMTP_PORT 587) ms=$(get SMTP_SECURITY starttls)
    add Email "Resolve $mh"       chk_dns "$mh"
    add Email "Connect $mh:$mp"   chk_tcp "$mh" "$mp" "SMTP" 0
    add Email "SMTP greeting"     chk_smtp_banner "$mh" "$mp" "$ms"
    case $ms in
      starttls) add Email "STARTTLS certificate" chk_tls "$mh" "$mp" smtp "$mh" warn "$DOC_NETWORK" ;;
      tls)      add Email "TLS certificate"      chk_tls "$mh" "$mp" ""   "$mh" warn "$DOC_NETWORK" ;;
    esac
  fi

  if [[ -n $(get LDAP_HOST) ]]; then
    local lh lp ls; lh=$(get LDAP_HOST) lp=$(get LDAP_PORT 636) ls=$(get LDAP_SECURITY ldaps)
    add "Directory & SSO" "Resolve $lh"     chk_dns "$lh"
    add "Directory & SSO" "Connect $lh:$lp" chk_tcp "$lh" "$lp" "LDAP" 0
    case $ls in
      ldaps)    add "Directory & SSO" "LDAPS certificate"    chk_tls "$lh" "$lp" ""   "$lh" fail "$DOC_NETWORK" ;;
      starttls) add "Directory & SSO" "StartTLS certificate" chk_tls "$lh" "$lp" ldap "$lh" fail "$DOC_NETWORK" ;;
      none)     add "Directory & SSO" "Connection security"  chk_ldap_cleartext ;;
    esac
    [[ -n $(get LDAP_BIND_DN) ]] && add "Directory & SSO" "Bind as service account" chk_ldap_bind
  fi
  if [[ -n $(get SSO_METADATA_URL) ]]; then
    url_parse "$(get SSO_METADATA_URL)"
    add "Directory & SSO" "IdP metadata ($U_HOST)" chk_http "$(get SSO_METADATA_URL)"
  fi

  if [[ -n $(get SEARCH_URL) ]]; then
    url_parse "$(get SEARCH_URL)"; INTERNAL_HTTP+=("$U_HOST")
    add "Search & cache" "Resolve $U_HOST"      chk_dns "$U_HOST" "$DOC_SEARCH"
    [[ $U_SCHEME == https ]] && add "Search & cache" "Search TLS certificate" chk_tls "$U_HOST" "$U_PORT" "" "$U_HOST" fail "$DOC_SEARCH"
    add "Search & cache" "Search cluster responds" chk_search "$(get SEARCH_URL)"
  fi
  if [[ -n $(get REDIS_HOST) ]]; then
    hp_split "$(get REDIS_HOST)" 6379
    add "Search & cache" "Redis $HP_HOST:$HP_PORT" chk_redis "$HP_HOST" "$HP_PORT"
  fi

  case $(get CALLS_MODE integrated) in
    integrated)
      if [[ -n $(get STUN_SERVER) ]] && ! is_yes "$(get AIR_GAPPED)"; then
        add Calls "Public address (STUN)" chk_stun "$(get STUN_SERVER)" "$(get ICE_HOST_OVERRIDE)"
      elif [[ -n $(get ICE_HOST_OVERRIDE) ]]; then
        add Calls "ICE host override resolves" chk_dns "$(get ICE_HOST_OVERRIDE)" "$DOC_CALLS"
      fi ;;
    rtcd)
      split_list rtcds "$(get RTCD_HOSTS)"
      for x in "${rtcds[@]}"; do
        hp_split "$x" 8045; INTERNAL_HTTP+=("$HP_HOST")
        add Calls "Resolve $HP_HOST"          chk_dns "$HP_HOST" "$DOC_RTCD"
        add Calls "RTCD API $HP_HOST:$HP_PORT" chk_rtcd_api "$HP_HOST" "$HP_PORT"
      done ;;
  esac
  if [[ -n $(get OFFLOADER_URL) ]]; then
    url_parse "$(get OFFLOADER_URL)"; INTERNAL_HTTP+=("$U_HOST")
    add Calls "Offloader API ($U_HOST)" chk_http "$(get OFFLOADER_URL)" "$DOC_OFFLOADER" 1
  fi

  if [[ -n $(get PUSH_SERVER) ]]; then
    url_parse "$(get PUSH_SERVER)"
    add "Push notifications" "Reach $U_HOST" chk_http "$(get PUSH_SERVER)" "$DOC_MOBILE"
  fi

  if is_yes "$(get AIR_GAPPED)"; then
    add Internet "Air-gapped mode" chk_note "internet checks skipped. Load plugins and licences offline, and plan push notifications without internet access" "$DOC_AIRGAP"
  else
    add Internet "Plugin Marketplace"  chk_http "https://api.integrations.mattermost.com/"
    add Internet "Release downloads"   chk_http "https://releases.mattermost.com/"
    add Internet "Customer portal"     chk_http "https://customers.mattermost.com/"
  fi
  plan_outbound_proxy

  if [[ -n $(get SITE_URL) ]]; then
    url_parse "$(get SITE_URL)"
    add "Site URL" "Resolve $U_HOST"  chk_dns "$U_HOST" "$DOC_NGINX"
    add "Site URL" "Live endpoint"    chk_site_live "$(get SITE_URL)"
  fi

  if [[ $(get FILE_STORE) == s3 ]]; then url_parse "$(get S3_ENDPOINT)"; perf+=("S3 endpoint|$U_HOST|$U_PORT"); fi
  for x in "${rtcds[@]}"; do hp_split "$x" 8045; perf+=("rtcd $HP_HOST|$HP_HOST|$HP_PORT"); done
  if [[ -n $(get SEARCH_URL) ]]; then url_parse "$(get SEARCH_URL)"; perf+=("search|$U_HOST|$U_PORT"); fi
  if [[ -n $(get REDIS_HOST) ]]; then hp_split "$(get REDIS_HOST)" 6379; perf+=("redis|$HP_HOST|$HP_PORT"); fi
  plan_perf "${perf[@]}"
}

plan_db() {
  local p min dsk; p=$(get DB_PORT 5432) min=$(get PG_MIN_VERSION 15) dsk=$(get MIN_DISK_GB "${DEF_DISK[db]}")
  plan_inbound "$p" tcp "PostgreSQL" postgres "the Mattermost app nodes" "$DOC_DB"
  local -a dbp; split_list dbp "$(get DB_PEERS)"
  add Capacity "Database sizing" chk_capacity db $(( ${#dbp[@]} + 1 ))
  add PostgreSQL "Server installed"     chk_pg_installed "$min"
  add PostgreSQL "Service running"      chk_pg_service
  add PostgreSQL "Network listener"     chk_pg_listen "$p"
  add PostgreSQL "Server settings"      chk_pg_settings
  add PostgreSQL "Connection capacity"  chk_pg_conns
  add PostgreSQL "Database & role"      chk_pg_objects "$(get DB_NAME mattermost)" "$(get DB_USER mmuser)"
  add PostgreSQL "Data directory space" chk_pg_space "$dsk"
  local -a nodes peers; local x
  split_list nodes "$(get APP_NODES)"
  for x in "${nodes[@]}"; do x=${x%%:*}; add "Client access" "pg_hba allows $x" chk_pg_hba "$x"; done
  split_list peers "$(get DB_PEERS)"
  for x in "${peers[@]}"; do hp_split "$x" "$p"; add Replication "Reach $HP_HOST:$HP_PORT" chk_tcp "$HP_HOST" "$HP_PORT" "PostgreSQL" 1 "$DOC_DB"; done
  local -a perf=()
  for x in "${nodes[@]}"; do perf+=("app ${x%%:*}|${x%%:*}|8065"); done
  for x in "${peers[@]}"; do hp_split "$x" "$p"; perf+=("peer $HP_HOST|$HP_HOST|$HP_PORT"); done
  plan_perf "${perf[@]}"
}

plan_proxy() {
  add Capacity "Proxy sizing" chk_capacity_proxy
  plan_inbound 80 tcp "HTTP" "nginx|haproxy|httpd|envoy" "clients" "$DOC_NGINX"
  plan_inbound 443 tcp "HTTPS" "nginx|haproxy|httpd|envoy" "clients" "$DOC_NGINX"
  url_parse "$(get SITE_URL)"; local site=$U_HOST
  add "Site URL" "Resolve $site"         chk_dns "$site" "$DOC_NGINX"
  add "Site URL" "Points at this server" chk_site_local "$site"
  local -a nodes; local x
  split_list nodes "$(get APP_NODES)"
  for x in "${nodes[@]}"; do
    hp_split "$x" 8065
    add "Upstream app servers" "Resolve $HP_HOST"            chk_dns "$HP_HOST" "$DOC_NGINX"
    add "Upstream app servers" "Reach $HP_HOST:$HP_PORT"     chk_tcp "$HP_HOST" "$HP_PORT" "Mattermost" 1 "$DOC_NGINX"
  done
  if [[ -n $(get TLS_CERT) ]]; then
    add "TLS certificate" "Certificate file" chk_cert_file "$(get TLS_CERT)" "$site"
    [[ -n $(get TLS_KEY) ]] && add "TLS certificate" "Private key" chk_key_match "$(get TLS_CERT)" "$(get TLS_KEY)"
  fi
  add NGINX "Configuration" chk_nginx_conf
  local -a perf=()
  for x in "${nodes[@]}"; do hp_split "$x" 8065; perf+=("app $HP_HOST|$HP_HOST|$HP_PORT"); done
  plan_perf "${perf[@]}"
}

plan_rtcd() {
  local rp ap; rp=$(get RTC_PORT 8443) ap=$(get RTCD_API_PORT 8045)
  plan_inbound "$rp" udp "Calls media" rtcd "Calls clients and offloader jobs" "$DOC_RTCD"
  plan_inbound "$rp" tcp "Calls media" rtcd "Calls clients and offloader jobs" "$DOC_RTCD"
  plan_inbound "$ap" tcp "RTCD API" rtcd "the Mattermost app nodes" "$DOC_RTCD"
  add "Kernel tuning" "UDP receive buffer" chk_sysctl net.core.rmem_max 16777216 warn "$DOC_RTCD"
  add "Kernel tuning" "UDP send buffer"    chk_sysctl net.core.wmem_max 16777216 warn "$DOC_RTCD"
  if [[ -n $(get STUN_SERVER) ]] && ! is_yes "$(get AIR_GAPPED)"; then
    add "NAT & ICE" "Public address (STUN)" chk_stun "$(get STUN_SERVER)" "$(get ICE_HOST_OVERRIDE)"
  elif [[ -n $(get ICE_HOST_OVERRIDE) ]]; then
    add "NAT & ICE" "ICE host override resolves" chk_dns "$(get ICE_HOST_OVERRIDE)" "$DOC_RTCD"
  fi
}

plan_offloader() {
  local u; u=$(get OFFLOADER_USER calls-offloader)
  plan_inbound "$(get OFFLOADER_PORT 4545)" tcp "Offloader API" "calls-offloader" "the Mattermost app nodes" "$DOC_OFFLOADER"
  add "Container runtime" "Docker Engine"  chk_docker
  add "Container runtime" "Service user"   chk_offloader_user "$u"
  add "Container runtime" "Job images"     chk_offloader_images
  url_parse "$(get SITE_URL)"; INTERNAL_HTTP+=("$U_HOST")
  add "Mattermost" "Resolve $U_HOST"       chk_dns "$U_HOST" "$DOC_OFFLOADER"
  add "Mattermost" "Reach site URL"        chk_http "$(get SITE_URL)" "$DOC_OFFLOADER" 1
  hp_split "$(get RTC_TARGET)" 8443
  add "Calls media" "Resolve $HP_HOST"     chk_dns "$HP_HOST" "$DOC_OFFLOADER"
  add "Calls media" "TCP $HP_HOST:$HP_PORT" chk_tcp "$HP_HOST" "$HP_PORT" "rtcd" 1 "$DOC_OFFLOADER"
  add "Calls media" "UDP $HP_HOST:$HP_PORT" chk_udp "$HP_HOST" "$HP_PORT" "rtcd" "$DOC_OFFLOADER"
  if ! is_yes "$(get AIR_GAPPED)"; then
    add Internet "Docker Hub registry" chk_http "https://registry-1.docker.io/v2/" "$DOC_OFFLOADER"
  fi
  plan_outbound_proxy
  hp_split "$(get RTC_TARGET)" 8443; url_parse "$(get SITE_URL)"
  plan_perf "Calls media $HP_HOST|$HP_HOST|$HP_PORT" "site $U_HOST|$U_HOST|$U_PORT"
}

plan_search() {
  local hp tp; hp=$(get SEARCH_PORT 9200) tp=$(get SEARCH_TRANSPORT_PORT 9300)
  plan_inbound "$hp" tcp "Search HTTP" "java|elasticsearch|opensearch" "the Mattermost app nodes" "$DOC_SEARCH"
  plan_inbound "$tp" tcp "Transport" "java|elasticsearch|opensearch" "the other search nodes" "$DOC_SEARCH"
  local -a sp; split_list sp "$(get SEARCH_PEERS)"
  add Capacity "Search node sizing" chk_capacity search $(( ${#sp[@]} + 1 ))
  add "Kernel tuning" "vm.max_map_count" chk_sysctl vm.max_map_count 262144 fail "$DOC_SEARCH"
  add "Kernel tuning" "Swap"             chk_swap
  local -a peers; local x
  split_list peers "$(get SEARCH_PEERS)"
  for x in "${peers[@]}"; do hp_split "$x" "$tp"; add "Cluster peers" "Reach $HP_HOST:$HP_PORT" chk_tcp "$HP_HOST" "$HP_PORT" "search" 1 "$DOC_SEARCH"; done
  local -a perf=()
  for x in "${peers[@]}"; do hp_split "$x" "$tp"; perf+=("peer $HP_HOST|$HP_HOST|$HP_PORT"); done
  plan_perf "${perf[@]}"
}

plan_pushproxy() {
  plan_inbound "$(get PUSH_PROXY_PORT 8066)" tcp "Push proxy" "push|mattermost" "the Mattermost app nodes" "$DOC_MOBILE"
  if is_yes "$(get AIR_GAPPED)"; then
    add "Apple & Google" "Air-gapped mode" chk_note "a push proxy needs outbound access to Apple and Google. Consider a relay in a DMZ" "$DOC_MOBILE"
  else
    add "Apple & Google" "Apple APNs"      chk_http "https://api.push.apple.com/" "$DOC_MOBILE"
    add "Apple & Google" "Firebase (FCM)"  chk_http "https://fcm.googleapis.com/" "$DOC_MOBILE"
    add "Apple & Google" "Google OAuth"    chk_http "https://oauth2.googleapis.com/" "$DOC_MOBILE"
  fi
  plan_outbound_proxy
}

# ════════════════════════════════════════════════════════════════════════════
#  Runner, summary, report
# ════════════════════════════════════════════════════════════════════════════
R_SEC=() R_LABEL=() R_STATUS=() R_DETAIL=() R_FIX=() R_DOC=()
declare -A COUNT=([PASS]=0 [WARN]=0 [FAIL]=0 [SKIP]=0 [INFO]=0)

run_plan() {
  local total=${#P_CMD[@]} i cur=""; local -a parts
  declare -A secn=()
  for ((i = 0; i < total; i++)); do secn[${P_SEC[i]}]=$(( ${secn[${P_SEC[i]}]:-0} + 1 )); done
  cursor hide
  exec 9>&2 2>> "$TMPD/stderr.log"     # keep stray tool noise out of the UI
  for ((i = 0; i < total; i++)); do
    if [[ ${P_SEC[i]} != "$cur" ]]; then cur=${P_SEC[i]}; section_header "$cur" "${secn[$cur]}"; fi
    IFS=$'\x1f' read -r -a parts <<< "${P_CMD[i]}"
    S_STATUS="" S_DETAIL="" S_FIX="" S_DOC=""
    spinner_start "${P_LABEL[i]}" $((i + 1)) "$total"
    "${parts[@]}"
    spinner_stop
    [[ -z $S_STATUS ]] && warn "check returned no result"
    R_SEC+=("${P_SEC[i]}") R_LABEL+=("${P_LABEL[i]}") R_STATUS+=("$S_STATUS")
    R_DETAIL+=("$S_DETAIL") R_FIX+=("$S_FIX") R_DOC+=("$S_DOC")
    COUNT[$S_STATUS]=$(( ${COUNT[$S_STATUS]} + 1 ))
    render_result "$S_STATUS" "${P_LABEL[i]}" "$S_DETAIL" "$S_FIX" "$S_DOC"
  done
  exec 2>&9 9>&-
  cursor show
}

verdict() {
  if (( COUNT[FAIL] > 0 )); then echo "NOT READY"; elif (( COUNT[WARN] > 0 )); then echo "READY WITH WARNINGS"; else echo "READY"; fi
}

summary() {
  local v vc vg; v=$(verdict)
  case $v in NOT*) vc=$RED vg=$G_FAIL ;; *WARN*) vc=$YELLOW vg=$G_WARN ;; *) vc=$GREEN vg=$G_PASS ;; esac
  local counts
  counts="$GREEN$G_PASS$RESET ${COUNT[PASS]} passed   $YELLOW$G_WARN$RESET ${COUNT[WARN]} warnings   "
  counts+="$RED$G_FAIL$RESET ${COUNT[FAIL]} failed   $GRAY$G_SKIP ${COUNT[SKIP]} skipped$RESET"
  printf '\n\n'
  local -a lines=("$vc$BOLD$vg  $v$RESET" "$GRAY${ROLE_NAME[$ROLE]} $G_DOT $HOST_SHORT $G_DOT $(date '+%d %b %Y %H:%M')$RESET" "" "$counts")
  [[ -n $CAPACITY_LINE ]] && lines+=("$BLUE$G_INFO$RESET $CAPACITY_LINE")
  box "${lines[@]}"

  local i n=0
  if (( COUNT[FAIL] > 0 )); then
    printf '\n  %sFix these first%s\n' "$BOLD" "$RESET"
    for i in "${!R_STATUS[@]}"; do
      [[ ${R_STATUS[i]} == FAIL ]] || continue
      n=$((n + 1))
      printf '\n  %s%2d%s  %s %s%s %s%s\n' "$RED$BOLD" "$n" "$RESET" "$(ax "${R_LABEL[i]}")" "$GRAY" "$G_DOT" "${R_SEC[i]}" "$RESET"
      printf '      %s%s%s\n' "$GRAY" "$(trunc "$(ax "${R_DETAIL[i]}")" $(( W - 8 )))" "$RESET"
    done
  fi
}

write_report() {
  local dir=${OPT_REPORT_DIR:-.}
  [[ -d $dir && -w $dir ]] || dir=${TMPDIR:-/tmp}
  REPORT="$dir/mm-preflight-${ROLE:-unknown}-${HOST_SHORT}-${STAMP}.txt"
  local i k rule; rule=$(printf '%*s' 78 '' | tr ' ' '=')
  {
    echo "MATTERMOST PRE-FLIGHT REPORT  v$MMPF_VERSION"
    echo "$rule"
    printf '%-12s %s\n' "Result:" "$(verdict)" "Role:" "${ROLE_NAME[${ROLE:-app}]:-?} (${ROLE:-?})" \
      "Host:" "$(hostname -f 2>/dev/null || hostname)$(i=$(local_ips | paste -sd, -); [[ -n $i ]] && echo " ($i)")" \
      "OS:" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")" "Run by:" "$(id -un)" \
      "Date:" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "Answers:" "${OPT_ANSWERS:-interactive}"
    [[ -n $CAPACITY_LINE ]] && printf '%-12s %s\n' "Capacity:" "$CAPACITY_LINE (per $DOC_SCALE)"
    printf '%-12s %s passed, %s warnings, %s failed, %s skipped, %s info\n' "Checks:" \
      "${COUNT[PASS]}" "${COUNT[WARN]}" "${COUNT[FAIL]}" "${COUNT[SKIP]}" "${COUNT[INFO]}"
    local st
    for st in FAIL WARN; do
      (( COUNT[$st] > 0 )) || continue
      echo; echo "$([[ $st == FAIL ]] && echo FAILURES || echo WARNINGS) (${COUNT[$st]})"; echo "${rule//=/-}"
      for i in "${!R_STATUS[@]}"; do
        [[ ${R_STATUS[i]} == "$st" ]] || continue
        echo "[$st] ${R_SEC[i]} > ${R_LABEL[i]}"
        echo "       Result: ${R_DETAIL[i]}"
        [[ -n ${R_FIX[i]} ]] && echo "       Fix:    ${R_FIX[i]}"
        [[ -n ${R_DOC[i]} ]] && echo "       Docs:   ${R_DOC[i]}"
        echo
      done
    done
    echo; echo "ALL CHECKS"; echo "${rule//=/-}"
    local last=""
    for i in "${!R_STATUS[@]}"; do
      [[ ${R_SEC[i]} != "$last" ]] && { last=${R_SEC[i]}; printf '\n%s\n' "$last"; }
      printf '  %-5s %-32s %s\n' "${R_STATUS[i]}" "${R_LABEL[i]}" "${R_DETAIL[i]}"
    done
    echo; echo "INPUTS (secrets masked)"; echo "${rule//=/-}"
    for k in "${ANS_ORDER[@]}"; do
      if is_secret "$k"; then printf '  %-22s %s\n' "$k" "$([[ -n ${ANS[$k]:-} ]] && echo '******** (provided)' || echo '(not provided)')"
      elif [[ $k == S3_ACCESS_KEY && -n ${ANS[$k]:-} ]]; then printf '  %-22s %s\n' "$k" "${ANS[$k]:0:4}…"
      else printf '  %-22s %s\n' "$k" "${ANS[$k]:-}"; fi
    done
    if ((${#INBOUND_FREE[@]})); then
      echo; echo "INBOUND PORTS"; echo "${rule//=/-}"
      echo "This server can't test its own inbound path. To let peers verify it, run here:"
      echo "  sudo ./$SELF --listen $(IFS=,; echo "${INBOUND_FREE[*]}")"
      echo "then run the pre-flight (or --probe) on the peer servers."
    fi
  } > "$REPORT" 2>/dev/null || REPORT=""
}

# ════════════════════════════════════════════════════════════════════════════
#  Listen & probe modes
# ════════════════════════════════════════════════════════════════════════════
run_listen() {
  ((HAS_PY)) || die "--listen needs python3 (dnf install -y python3)"
  local spec kind port; local -a specs
  IFS=',' read -r -a specs <<< "$OPT_LISTEN"
  for spec in "${specs[@]}"; do
    [[ $spec =~ ^(tcp|udp|perf):([0-9]{1,5})$ ]] || die "bad --listen spec '$spec' (use tcp:PORT, udp:PORT or perf:PORT)"
  done
  banner
  mode_header "Temporary test listeners"
  note "Peer servers can now prove their network path to $HOST_SHORT."
  note "Run the pre-flight (or --probe) on them. Every connection is shown below."
  [[ $OPT_LISTEN == *perf:* ]] && note "perf ports accept bandwidth tests (PERF_TEST=yes, or --probe perf:$HOST_SHORT:PORT)."
  note "Stops after ${OPT_DURATION}s or Ctrl-C. Nothing is changed on this server."
  if [[ $FW_STATE == active ]]; then
    for spec in "${specs[@]}"; do
      kind=${spec%%:*} port=${spec##*:}; [[ $kind == perf ]] && kind=tcp
      fw_allows "$port" "$kind" || printf '  %s%s%s firewalld does not allow %s/%s, so peers will fail until it is opened\n' \
                                         "$YELLOW" "$G_WARN" "$RESET" "$port" "$kind"
    done
  fi
  printf '\n'
  trap 'true' INT
  python3 -I -c "$PY_LISTEN" "$OPT_LISTEN" "$OPT_DURATION" "$GREEN$G_PASS$RESET" "$RED$G_FAIL$RESET"
  local rc=$?
  trap on_int INT
  printf '\n'; exit $(( rc == 0 ? 0 : 2 ))
}

run_probe() {
  local spec proto host port worst=0; local -a specs
  IFS=',' read -r -a specs <<< "$OPT_PROBE"
  banner
  mode_header "Network probes from $HOST_SHORT"
  section_header "Probes" "${#specs[@]}"
  for spec in "${specs[@]}"; do
    [[ $spec =~ ^(tcp|udp|perf|rtt):([A-Za-z0-9.-]+):([0-9]{1,5})$ ]] || die "bad --probe spec '$spec' (use tcp|udp|rtt|perf:HOST:PORT)"
    proto=${BASH_REMATCH[1]} host=${BASH_REMATCH[2]} port=${BASH_REMATCH[3]}
    S_STATUS="" S_DETAIL="" S_FIX="" S_DOC=""
    spinner_start "$proto $host:$port" 1 1
    case $proto in
      tcp)  chk_tcp "$host" "$port" "the service" 1 2>> "$TMPD/stderr.log" ;;
      udp)  chk_udp "$host" "$port" "the service" 2>> "$TMPD/stderr.log" ;;
      rtt)  chk_latency "$host" "$port" 2>> "$TMPD/stderr.log" ;;
      perf) chk_bandwidth "$host" "$port" 2>> "$TMPD/stderr.log" ;;
    esac
    spinner_stop 2>> "$TMPD/stderr.log"
    render_result "$S_STATUS" "${proto^^} $host:$port" "$S_DETAIL" "$S_FIX" "$S_DOC"
    [[ $S_STATUS == FAIL ]] && worst=2; [[ $S_STATUS == WARN && $worst -lt 1 ]] && worst=1
  done
  printf '\n'; exit "$worst"
}

# ════════════════════════════════════════════════════════════════════════════
#  Main
# ════════════════════════════════════════════════════════════════════════════
ROLE="" REPORT="" MAIN_PID=$BASHPID
on_exit() { [[ $BASHPID == "$MAIN_PID" ]] || return 0; spinner_stop; cursor show; [[ -n $TMPD && -d $TMPD ]] && rm -rf "$TMPD"; }
on_int() {
  [[ $BASHPID == "$MAIN_PID" ]] || exit 130
  spinner_stop; cursor show
  printf '\n\n  %s%s Interrupted.%s\n' "$YELLOW" "$G_WARN" "$RESET"
  if ((${#R_STATUS[@]})); then write_report; [[ -n $REPORT ]] && printf '  %sPartial report: %s%s\n' "$GRAY" "$REPORT" "$RESET"; fi
  exit 130
}

main() {
  parse_args "$@"
  setup_ui
  if [[ -n $OPT_TEMPLATE ]]; then print_template "$OPT_TEMPLATE"; exit 0; fi
  detect_env
  trap on_exit EXIT
  trap on_int INT TERM
  [[ -n $OPT_LISTEN ]] && run_listen
  [[ -n $OPT_PROBE ]] && run_probe
  [[ -n $OPT_ANSWERS ]] && load_answers
  [[ -n $OPT_ROLE ]] && ANS[ROLE]=$OPT_ROLE

  banner
  printf '\n'
  note "Checks that this server is ready for a Mattermost component before you install it."
  note "It reads settings and opens short test connections. It does not install or change anything."
  ((IS_ROOT)) || printf '  %s%s%s Not running as root: some checks will be limited. Re-run with sudo for full results.\n' "$YELLOW" "$G_WARN" "$RESET"

  step_header 1 3 "What is this server for?"
  choose_role

  step_header 2 3 "About your environment"
  if ((INTERACTIVE)); then note "Press Enter to accept the value in [brackets]. Leave optional items blank to skip them."; fi
  "interview_$ROLE"
  interview_perf
  check_tuning
  local n_asked=${#ANS_ORDER[@]}
  ((INTERACTIVE)) || printf '  %s%s%s  %d answers loaded%s\n' "$GREEN" "$G_PASS" "$RESET" "$n_asked" \
                            "$([[ -n $OPT_ANSWERS ]] && echo " from $OPT_ANSWERS")"

  if [[ -n $(get OUTBOUND_PROXY) ]]; then
    HTTP_PROXY=$(get OUTBOUND_PROXY); NO_PROXY=$(get NO_PROXY_LIST)
    export HTTP_PROXY HTTPS_PROXY=$HTTP_PROXY http_proxy=$HTTP_PROXY https_proxy=$HTTP_PROXY NO_PROXY no_proxy=$NO_PROXY
  else
    unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
  fi

  plan_system
  "plan_$ROLE"

  local nsec; nsec=$(printf '%s\n' "${P_SEC[@]}" | sort -u | wc -l)
  step_header 3 3 "Running ${#P_CMD[@]} checks across $nsec areas"
  if ((INTERACTIVE)); then
    printf '  %sPress Enter to start, or Ctrl-C to cancel.%s ' "$GRAY" "$RESET"; IFS= read -r _ < /dev/tty || true
  fi

  run_plan
  summary
  write_report
  if [[ -n $REPORT ]]; then
    printf '\n  %sReport%s   %s\n' "$BOLD" "$RESET" "$REPORT"
  else
    printf '\n  %s%s Could not write the report file.%s\n' "$YELLOW" "$G_WARN" "$RESET"
  fi

  if ((${#INBOUND_FREE[@]})); then
    printf '\n  %sNext%s     This server can'"'"'t test its own inbound path. Let peers verify it with:\n' "$BOLD" "$RESET"
    printf '           %ssudo ./%s --listen %s%s\n' "$BLUE" "$SELF" "$(IFS=,; echo "${INBOUND_FREE[*]}")" "$RESET"
  fi

  if [[ -n $OPT_SAVE ]]; then
    save_answers "$OPT_SAVE" && printf '\n  %s%s%s  Answers saved to %s %s(secrets excluded)%s\n' "$GREEN" "$G_PASS" "$RESET" "$OPT_SAVE" "$GRAY" "$RESET"
  elif ((INTERACTIVE)); then
    local f="mm-preflight-${ROLE}.conf" a
    printf '\n  %s%s%s Save your answers to %s for next time? %s[Y/n]%s ' "$YELLOW" "$G_Q" "$RESET" "$f" "$GRAY" "$RESET"
    IFS= read -r a < /dev/tty || a=n
    if [[ -z $a ]] || is_yes "$a"; then
      save_answers "$f" && printf '  %s%s%s  Saved %s(secrets excluded)%s. Re-run with: sudo ./%s -a %s\n' "$GREEN" "$G_PASS" "$RESET" "$GRAY" "$RESET" "$SELF" "$f"
    fi
  fi

  if ((INTERACTIVE && ${#INBOUND_FREE[@]})) && ((HAS_PY)); then
    local a
    printf '\n  %s%s%s Start the test listeners now? %s[y/N]%s ' "$YELLOW" "$G_Q" "$RESET" "$GRAY" "$RESET"
    IFS= read -r a < /dev/tty || a=n
    if is_yes "$a"; then OPT_LISTEN=$(IFS=,; echo "${INBOUND_FREE[*]}"); run_listen; fi
  fi
  printf '\n'

  case $(verdict) in NOT*) exit 2 ;; *WARN*) exit 1 ;; *) exit 0 ;; esac
}

main "$@"
