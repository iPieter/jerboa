# shellcheck shell=bash
#
# Shared helpers for the Jerboa ops scripts. This file is sourced, never run.
# Each phase script starts with:
#
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
#
# Ground rules for everything in deploy/:
#   * Nothing prints a secret. Secrets stay in shell variables and are written
#     to files with printf, which is a bash builtin, so they never appear in
#     `ps` output or in the transcript log.
#   * Never `set -x` in these scripts; it would echo secrets.
#   * State that has to survive between runs (which container was the previous
#     one, backups of configs, logs) lives in $STATE_DIR.
#
# Every path below can be overridden from the environment. The tests in
# deploy/tests/ use that to run the pure-local parts in a temp dir.

set -Eeuo pipefail
umask 022

: "${STATE_DIR:=/root/jerboa-state}"
: "${LOG_DIR:=$STATE_DIR/logs}"
: "${ENV_FILE:=/root/jerboa.env}"
: "${BACKUP_DIR:=/root/backups}"
: "${UPLOADS_DIR:=/root/chat_images}"
: "${EMOJIS_DIR:=/root/chat_emoijs}"   # sic: the directory on the server really is "emoijs"
: "${SRC_DIR:=/root/jerboa-src}"
: "${REPO_URL:=https://github.com/iPieter/jerboa.git}"
: "${PUBLIC_HOST:=chat.ipieter.be}"
: "${APP_PORT:=9000}"
: "${BASE_IMAGE:=chat:latest}"          # the original 2020 image; never retagged
: "${APP_CONTAINER_PREFIX:=jerboa-app}"
: "${DB_CONTAINER_NEW:=jerboa-db}"
: "${PGDATA_NEW:=/root/pgdata16}"
: "${PG_IMAGE:=postgres:16}"
: "${BACKUP_CONF:=/etc/jerboa-backup.conf}"
: "${ASSUME_YES:=0}"

PHASE=${PHASE:-jerboa}
ROLLBACK_CMD=""
CLEANUP_CMDS=()

# ---------------------------------------------------------------- output ----

if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YLW=$'\033[33m'
  C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YLW=''; C_BLD=''; C_DIM=''; C_RST=''
fi

ts_utc() { date -u +%Y%m%dT%H%M%SZ; }
log()  { printf '%s%s%s %s\n' "$C_DIM" "$(date -u +%H:%M:%S)" "$C_RST" "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_RST"; }
ok()   { printf '%s  ok%s  %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '%sWARN%s  %s\n' "$C_YLW" "$C_RST" "$*" >&2; }
die()  { printf '%sFAIL%s  %s\n' "$C_RED" "$C_RST" "$*" >&2; print_rollback >&2; exit 1; }
indent() { sed 's/^/    /'; }

# Tee everything this script prints into $LOG_DIR/<phase>-<ts>.log.
start_log() {
  mkdir -p "$LOG_DIR"
  chmod 700 "$STATE_DIR" "$LOG_DIR" 2>/dev/null || true
  LOG_FILE="$LOG_DIR/$PHASE-$(ts_utc).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "Transcript: $LOG_FILE"
}

set_rollback() { ROLLBACK_CMD=$1; }

print_rollback() {
  [[ -n $ROLLBACK_CMD ]] || return 0
  printf '\n%s---- ROLLBACK (%s) ----------------------------------------%s\n' "$C_BLD" "$PHASE" "$C_RST"
  printf '%s\n' "$ROLLBACK_CMD" | sed 's/^/  /'
  printf '%s----------------------------------------------------------------%s\n' "$C_BLD" "$C_RST"
}

cleanup_add() { CLEANUP_CMDS+=("$1"); }

_run_cleanups() {
  local c
  for c in ${CLEANUP_CMDS[@]+"${CLEANUP_CMDS[@]}"}; do
    eval "$c" >/dev/null 2>&1 || true
  done
}

# With errtrace (-E) the ERR trap also runs inside $(...) and other subshells,
# even when the outer command is an `if` condition. Only report at the top
# level: a real failure inside a subshell makes the outer command fail too.
_on_err() {
  local rc=$? line=${BASH_LINENO[0]:-?}
  (( BASH_SUBSHELL == 0 )) || return 0
  printf '\n%sFAILED%s (exit %s) near line %s: %s\n' "$C_RED" "$C_RST" "$rc" "$line" "$BASH_COMMAND" >&2
  print_rollback >&2
}

trap _on_err ERR
trap _run_cleanups EXIT

# ------------------------------------------------------------- prompts ----

# confirm "Question?" [word]  -> returns 0 only if the user types <word>.
# --yes (ASSUME_YES=1) skips the prompt.
confirm() {
  local q=$1 word=${2:-yes} ans=""
  if [[ $ASSUME_YES == 1 ]]; then
    log "(--yes) $q -> $word"
    return 0
  fi
  [[ -t 0 ]] || die "Need an interactive terminal to confirm (or pass --yes)."
  read -r -p "$q Type '$word' to continue: " ans
  [[ $ans == "$word" ]]
}

# ask_yn "Question?" <default y|n> -> 0 for yes. Without a terminal, or with
# --yes, the default is used.
ask_yn() {
  local q=$1 def=${2:-n} ans=""
  if [[ $ASSUME_YES == 1 || ! -t 0 ]]; then
    log "$q -> $def (default)"
    [[ $def == y ]]
    return
  fi
  if [[ $def == y ]]; then read -r -p "$q [Y/n] " ans; ans=${ans:-y}
  else read -r -p "$q [y/N] " ans; ans=${ans:-n}; fi
  [[ $ans == [yY]* ]]
}

# ----------------------------------------------------------- pre-flight ----

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this as root (ssh root@$PUBLIC_HOST)."; }

require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [[ ${#missing[@]} -eq 0 ]] || die "Missing commands: ${missing[*]}"
}

# free MB on the filesystem holding <path>
disk_free_mb() { df -Pm "$1" | awk 'NR==2 {print $4}'; }

mem_available_mb() { awk '/^MemAvailable:/ {print int($2/1024)}' /proc/meminfo; }

require_disk_mb() { # <path> <MB> <why>
  local free
  free=$(disk_free_mb "$1")
  (( free >= $2 )) || die "Only ${free} MB free on $1, need ${2} MB ($3)."
  ok "disk: ${free} MB free on $1 (need ${2} MB for $3)"
}

# ------------------------------------------------------------- secrets ----

gen_secret() { openssl rand -hex 32; }

# env_get KEY FILE -> prints the value (docker --env-file semantics: the value
# is everything after the first '=', taken literally). Returns 1 if absent.
env_get() {
  local key=$1 file=$2 line
  line=$(grep -m1 -E "^${key}=" "$file" 2>/dev/null) || return 1
  printf '%s' "${line#*=}"
}

env_has() { grep -qE "^${1}=." "$2" 2>/dev/null; }

# env_set KEY VALUE FILE: replace or append KEY, keep every other line, write
# atomically with mode 0600. The value must be a single line.
env_set() {
  local key=$1 val=$2 file=$3 tmp
  [[ $val != *$'\n'* ]] || die "env_set: value for $key contains a newline"
  tmp=$(mktemp "$(dirname "$file")/.$(basename "$file").XXXXXX")
  chmod 600 "$tmp"
  if [[ -f $file ]]; then
    grep -vE "^${key}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv -f "$tmp" "$file"
}

# Keep a dated 0600 copy of a secrets file before changing it.
backup_secret_file() { # <file> <tag>
  local dst
  dst="$STATE_DIR/$(basename "$1").$2-$(ts_utc)"
  mkdir -p "$STATE_DIR"
  (umask 077; cp -p "$1" "$dst")
  chmod 600 "$dst"
  printf '%s' "$dst"
}

check_secret_file_mode() { # <file>
  local mode
  mode=$(stat -c '%a' "$1")
  if [[ $mode != 600 ]]; then
    warn "$1 had mode $mode; fixing to 600"
    chmod 600 "$1"
  fi
}

# --------------------------------------------------------------- docker ----

container_exists()  { docker container inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == true ]]; }
container_image()   { docker container inspect -f '{{.Config.Image}}' "$1"; }

# Running containers that serve the chat backend: our labelled ones, or the
# legacy hand-started one (image "chat").
find_running_app_containers() {
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Label "jerboa.role"}}' |
    awk -F'\t' '$3 == "app" || $2 == "chat" || $2 ~ /^chat:/ {print $1}'
}

# Running containers that have something mounted on the Postgres data dir.
find_running_pg_containers() {
  local c
  for c in $(docker ps --format '{{.Names}}'); do
    if docker container inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$c" |
        grep -qx /var/lib/postgresql/data; then
      printf '%s\n' "$c"
    fi
  done
}

# Start one backend container. Everything that matters is explicit here so
# a rollback recreates exactly the same thing.
run_app_container() { # <name> <image> <env-file>
  docker run -d \
    --name "$1" \
    --label jerboa.role=app \
    --network host \
    --restart unless-stopped \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    --env-file "$3" \
    -v "$UPLOADS_DIR:/chat_app/data" \
    -v "$EMOJIS_DIR:/chat_app/emojis" \
    -w /chat_app \
    "$2" pipenv run python run.py >/dev/null
}

# The 2019 postgres image predates STOPSIGNAL SIGINT, so `docker stop` sends
# SIGTERM ("smart" shutdown: wait for every client to leave) and then SIGKILLs
# after the timeout, which forces crash recovery on the next start. Ask for a
# fast shutdown (SIGINT) instead and wait for it.
stop_pg_container() { # <name>
  local name=$1 i
  container_running "$name" || return 0
  docker kill --signal=SIGINT "$name" >/dev/null
  for i in $(seq 1 60); do
    container_running "$name" || { ok "postgres in $name shut down cleanly (${i}s)"; return 0; }
    sleep 1
  done
  warn "$name did not stop after 60s of SIGINT; falling back to docker stop"
  docker stop -t 30 "$name" >/dev/null
}

wait_pg_ready() { # <container> <user> [timeout] [port]
  local c=$1 u=$2 t=${3:-90} port=${4:-5432} i
  for i in $(seq 1 "$t"); do
    # -h 127.0.0.1 on purpose: during first-time init the image runs a
    # temporary socket-only server, which must not count as "ready".
    if docker exec "$c" pg_isready -q -h 127.0.0.1 -p "$port" -U "$u" >/dev/null 2>&1; then
      ok "postgres in $c accepts TCP connections on 127.0.0.1:$port (${i}s)"
      return 0
    fi
    sleep 1
  done
  return 1
}

port_listening() { ss -ltn "( sport = :$1 )" | grep -q LISTEN; }

wait_port_free() { # <port> [seconds]
  local i
  for i in $(seq 1 "${2:-15}"); do
    port_listening "$1" || return 0
    sleep 1
  done
  return 1
}

# Names of the env vars a container was created with (never the values).
container_env_names() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" | cut -d= -f1; }

# ---------------------------------------------------------------- http ----

http_code() { # <url> [extra curl args...]
  local url=$1; shift
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url" || true
}

# Health check of the backend that does not need a login:
#   1. GET /status                       -> 200, {"backend": 0, "database": [0, ...]}
#   2. GET /files?f=<nonexistent>        -> 404, proves a real DB query works
#   3. socket.io polling handshake       -> body contains "sid"
#   4. GET https://<host>/api/status via the local nginx -> 200
app_health_check() { # [timeout-seconds]
  local timeout=${1:-90} deadline body code
  deadline=$(( $(date +%s) + timeout ))
  log "Waiting up to ${timeout}s for the backend on 127.0.0.1:$APP_PORT ..."
  while :; do
    body=$(curl -fsS --max-time 3 "http://127.0.0.1:$APP_PORT/status" 2>/dev/null || true)
    [[ -n $body ]] && break
    if (( $(date +%s) >= deadline )); then
      warn "backend did not answer /status within ${timeout}s"
      return 1
    fi
    sleep 2
  done
  if ! printf '%s' "$body" | python3 -c '
import json, sys
d = json.load(sys.stdin)
good = True
if "backend" in d:
    good = good and d["backend"] == 0
if "database" in d:
    db = d["database"]
    good = good and (db[0] if isinstance(db, list) else db) == 0
sys.exit(0 if good else 1)
' 2>/dev/null; then
    warn "/status answered but reports a problem: ${body:0:200}"
    return 1
  fi
  ok "GET /status -> $body"

  code=$(http_code "http://127.0.0.1:$APP_PORT/files?f=jerboa-healthcheck-nonexistent")
  case $code in
    404) ok "GET /files?f=<nonexistent> -> 404 (database query path works)" ;;
    401|403) warn "GET /files -> $code (endpoint now needs auth?); DB query path not proven" ;;
    *) warn "GET /files?f=<nonexistent> -> $code (expected 404)"; return 1 ;;
  esac

  body=$(curl -fsS --max-time 5 "http://127.0.0.1:$APP_PORT/socket.io/?EIO=3&transport=polling&t=jerboa-hc" 2>/dev/null || true)
  if [[ $body == *'"sid"'* ]]; then
    ok "socket.io polling handshake works"
  else
    warn "socket.io handshake failed: ${body:0:200}"
    return 1
  fi

  code=$(http_code "https://$PUBLIC_HOST/api/status" --resolve "$PUBLIC_HOST:443:127.0.0.1")
  if [[ $code == 200 ]]; then
    ok "GET https://$PUBLIC_HOST/api/status through nginx -> 200"
  else
    warn "through nginx: https://$PUBLIC_HOST/api/status -> $code"
    return 1
  fi
}

# Check that the backend process (PID 1 in the container; pipenv execs python)
# really runs with the values from $ENV_FILE. Compares SHA-256 hashes inside
# this shell; prints only "match"/"MISMATCH", never a value or a hash.
verify_runtime_env() { # <container>
  local key want got bad=0
  for key in $(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" | tr -d '='); do
    want=$(env_get "$key" "$ENV_FILE" | sha256sum | cut -d' ' -f1)
    got=$(docker exec "$1" python3 -c '
import hashlib, sys
env = dict(kv.split(b"=", 1) for kv in open("/proc/1/environ", "rb").read().split(b"\0") if b"=" in kv)
v = env.get(sys.argv[1].encode())
print(hashlib.sha256(v).hexdigest() if v is not None else "absent")' "$key" 2>/dev/null || echo error)
    if [[ $want == "$got" ]]; then
      ok "runtime env: $key matches $ENV_FILE"
    else
      case $got in
        absent) warn "runtime env: $key is missing in the running process" ;;
        error)  warn "runtime env: could not read the environment of PID 1 in $1" ;;
        *)      warn "runtime env: $key differs from $ENV_FILE (a baked-in .env overriding it?)" ;;
      esac
      bad=1
    fi
  done
  return "$bad"
}

# Print the last lines of a container's log, for when something failed.
show_container_logs() { # <name> [lines]
  printf '%s---- last %s log lines of %s ----%s\n' "$C_DIM" "${2:-40}" "$1" "$C_RST"
  docker logs --tail "${2:-40}" "$1" 2>&1 | sed 's/^/  | /' || true
}

# Point the nightly backup (/etc/jerboa-backup.conf) at another database.
# No-op if backup.sh never ran.
set_backup_target() { # <container> <user> <db>
  [[ -f $BACKUP_CONF ]] || { warn "$BACKUP_CONF not found; run backup.sh to install nightly backups"; return 0; }
  mkdir -p "$STATE_DIR"
  cp -p "$BACKUP_CONF" "$STATE_DIR/$(basename "$BACKUP_CONF").$(ts_utc)"
  sed -e "s|^DB_CONTAINER=.*|DB_CONTAINER=$1|" -e "s|^DB_USER=.*|DB_USER=$2|" \
      -e "s|^DB_NAME=.*|DB_NAME=$3|" "$BACKUP_CONF" > "$BACKUP_CONF.new"
  cat "$BACKUP_CONF.new" > "$BACKUP_CONF"   # keeps owner and mode
  rm -f "$BACKUP_CONF.new"
  ok "nightly backup now dumps database '$3' from container '$1'"
}

# ---------------------------------------------------------------- state ----

state_get() { cat "$STATE_DIR/$1" 2>/dev/null || true; }
state_set() { mkdir -p "$STATE_DIR"; printf '%s\n' "$2" > "$STATE_DIR/$1"; }

# --help: print the comment block at the top of the calling script.
usage_and_exit() { sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"; exit "${1:-0}"; }
