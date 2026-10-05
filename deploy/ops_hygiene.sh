#!/usr/bin/env bash
# Phase 6: log hygiene and cleanup. No downtime; restarts nothing but journald.
#
#   ./ops_hygiene.sh              steps 1-3, then offer step 4
#   ./ops_hygiene.sh --prune-only only step 4
#   ./ops_hygiene.sh --rollback   undo steps 1-3 (pruned containers cannot come back)
#   options:
#     --include-old-db   let step 4 also offer the stopped pre-migration DB container
#     --yes              skip the questions of steps 1-3; step 4 ALWAYS asks
#
# 1. logrotate for /root/chat/logs/nginx_{access,error}.log (632 MB, never
#    rotated): daily, 14 days, gzip. Offers a first rotation right away.
# 2. journald cap: SystemMaxUse=300M (the journal is 1.5 GB), vacuum now.
# 3. Docker defaults in /etc/docker/daemon.json: json-file logs, 10m x 3.
#    dockerd only reads this when it starts, and it only affects containers
#    created afterwards. Running containers keep what they have; the ones the
#    deploy scripts create already pass these options explicitly. Docker is NOT
#    restarted here (that would stop every container); it takes effect at the
#    next reboot / docker restart.
# 4. Old exited containers (about 20, holding ~6.3 GB of logs): list them with
#    their log sizes, leave out rollback targets, and remove them only after you
#    type "prune". `docker rm` without -v: volumes and bind-mounted data stay.
#
# The OS upgrade and reboot are NOT automated; see RUNBOOK.md.

PHASE=ops_hygiene
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

LOGROTATE_FILE=/etc/logrotate.d/jerboa-nginx
JOURNALD_FILE=/etc/systemd/journald.conf.d/jerboa.conf
: "${DAEMON_JSON:=/etc/docker/daemon.json}"

MODE=all
INCLUDE_OLD_DB=0
for arg in "$@"; do
  case $arg in
    --prune-only) MODE=prune ;;
    --rollback) MODE=rollback ;;
    --include-old-db) INCLUDE_OLD_DB=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage_and_exit ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

# ------------------------------------------------------------- helpers ----

# Merge our log defaults into daemon.json (creating it if needed) and print
# the result. Other keys are kept. Fails on invalid JSON.
merge_daemon_json() { # <existing-file-or-empty>
  python3 - "$1" <<'PY'
import json, sys
path = sys.argv[1]
cfg = {}
if path:
    with open(path) as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        sys.exit("daemon.json is not a JSON object")
cfg["log-driver"] = "json-file"
opts = cfg.get("log-opts") or {}
opts.update({"max-size": "10m", "max-file": "3"})
cfg["log-opts"] = opts
print(json.dumps(cfg, indent=2, sort_keys=True))
PY
}

list_logs() { find /root/chat/logs -maxdepth 1 -type f -printf '    %10s  %TY-%Tm-%Td %TH:%TM  %f\n' | sort -k4; }

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "${1}B"; }

do_logrotate() {
  step "1. logrotate for the chat's nginx logs"
  if cmp -s "$SCRIPT_DIR/files/logrotate-jerboa-nginx" "$LOGROTATE_FILE"; then
    ok "$LOGROTATE_FILE already installed"
  else
    install -m 0644 -o root -g root "$SCRIPT_DIR/files/logrotate-jerboa-nginx" "$LOGROTATE_FILE"
    ok "installed $LOGROTATE_FILE"
  fi
  if logrotate -d "$LOGROTATE_FILE" > "$WORK/logrotate.debug" 2>&1; then
    ok "logrotate -d (dry run) accepts it"
  else
    sed 's/^/    /' "$WORK/logrotate.debug"
    rm -f "$LOGROTATE_FILE"
    die "logrotate rejected the config; removed it again"
  fi
  list_logs
  log "The access log may matter for the incident review: the first rotation keeps it,"
  log "uncompressed, as nginx_access.log-$(date -u +%Y%m%d) for 14 days. Copy it elsewhere to keep it longer."
  if ask_yn "Rotate now instead of waiting for tonight's cron run?" y; then
    logrotate -f "$LOGROTATE_FILE"
    ok "rotated; nginx reopened its logs"
    list_logs
  fi
}

do_journald() {
  step "2. journald size cap"
  log "journal now: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -n1)"
  mkdir -p "$(dirname "$JOURNALD_FILE")"
  if cmp -s "$SCRIPT_DIR/files/journald-jerboa.conf" "$JOURNALD_FILE"; then
    ok "$JOURNALD_FILE already installed"
  else
    install -m 0644 -o root -g root "$SCRIPT_DIR/files/journald-jerboa.conf" "$JOURNALD_FILE"
    ok "installed $JOURNALD_FILE (SystemMaxUse=300M)"
  fi
  # journald keeps client connections across a restart (its fd store), so this
  # does not disturb running services.
  systemctl restart systemd-journald
  journalctl --vacuum-size=300M 2>&1 | tail -n1 | sed 's/^/    /'
  ok "journal now: $(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[KMGT]' | head -n1)"
}

do_docker_defaults() {
  step "3. Docker log defaults ($DAEMON_JSON)"
  local existing="" new="$WORK/daemon.json"
  [[ -f $DAEMON_JSON ]] && existing=$DAEMON_JSON
  merge_daemon_json "$existing" > "$new" || die "$DAEMON_JSON is not valid JSON; fix it by hand first"
  python3 -m json.tool "$new" >/dev/null || die "generated daemon.json is invalid (bug)"
  if [[ -n $existing ]] && cmp -s "$new" "$existing"; then
    ok "already set"
    return 0
  fi
  if [[ -n $existing ]]; then
    cp -p "$existing" "$STATE_DIR/daemon.json.$(ts_utc)"
    log "previous $DAEMON_JSON saved in $STATE_DIR/"
  else
    : > "$STATE_DIR/daemon.json.absent"   # rollback marker: there was none
  fi
  sed 's/^/    /' "$new"
  install -m 0644 -o root -g root "$new" "$DAEMON_JSON"
  ok "wrote $DAEMON_JSON"
  warn "Not restarting docker. This applies to containers created after the next"
  warn "docker restart or reboot. A broken daemon.json would keep docker from starting,"
  warn "which is why the file was validated above."
}

do_prune() {
  step "4. Old exited containers"
  local -a keep=() cand=()
  local prev olddb c total=0 size logpath free_before
  prev=$(state_get app.previous)
  olddb=$(state_get db.old_container)
  [[ -n $prev ]] && keep+=("$prev")
  [[ $INCLUDE_OLD_DB == 0 && -n $olddb ]] && keep+=("$olddb")
  keep+=("$DB_CONTAINER_NEW")
  while IFS= read -r c; do
    [[ -n $c ]] || continue
    if printf '%s\n' ${keep[@]+"${keep[@]}"} | grep -qx "$c"; then continue; fi
    if [[ $(docker inspect -f '{{index .Config.Labels "jerboa.keep"}}' "$c" 2>/dev/null) == true ]]; then continue; fi
    cand+=("$c")
  done < <(docker ps -a --filter status=exited --filter status=created --filter status=dead --format '{{.Names}}')

  if (( ${#keep[@]} > 0 )); then
    log "kept as rollback targets: ${keep[*]}"
    [[ $INCLUDE_OLD_DB == 0 && -n $olddb ]] && log "(the pre-migration DB '$olddb' is only offered with --include-old-db)"
  fi
  if (( ${#cand[@]} == 0 )); then
    ok "no exited containers to remove"
    return 0
  fi

  printf '    %-28s %-22s %-28s %10s\n' NAME IMAGE STATUS LOG
  for c in "${cand[@]}"; do
    logpath=$(docker inspect -f '{{.LogPath}}' "$c")
    size=0
    [[ -n $logpath && -f $logpath ]] && size=$(stat -c %s "$logpath")
    total=$((total + size))
    printf '    %-28s %-22s %-28s %10s\n' "$c" "$(docker inspect -f '{{.Config.Image}}' "$c" | cut -c1-22)" \
      "$(docker ps -a --filter "name=^${c}\$" --format '{{.Status}}' | cut -c1-28)" "$(human "$size")"
  done
  log "${#cand[@]} containers, $(human "$total") of logs. Their images, volumes and bind-mounted data are kept."
  warn "Removed containers cannot be restored."
  # Always ask, even with --yes.
  local ASSUME_YES=0
  confirm "Remove these ${#cand[@]} containers?" prune || { log "Nothing removed."; return 0; }
  free_before=$(disk_free_mb /var/lib/docker)
  for c in "${cand[@]}"; do
    docker rm "$c" >/dev/null && log "removed $c"
  done
  ok "freed $(( $(disk_free_mb /var/lib/docker) - free_before )) MB"
  if [[ -n $(docker images -f dangling=true -q) ]]; then
    docker images -f dangling=true --format '    {{.ID}}  {{.CreatedSince}}  {{.Size}}'
    if ask_yn "Also remove these untagged, unused images (docker image prune)?" n; then
      docker image prune -f | tail -n1 | sed 's/^/    /'
    fi
  fi
}

do_rollback() {
  step "Rollback of steps 1-3"
  confirm "Remove the logrotate and journald files and restore daemon.json?" rollback || die "aborted"
  rm -f "$LOGROTATE_FILE" && ok "removed $LOGROTATE_FILE"
  if [[ -f $JOURNALD_FILE ]]; then
    rm -f "$JOURNALD_FILE"
    systemctl restart systemd-journald
    ok "removed $JOURNALD_FILE, journald restarted"
  fi
  local last=""
  for f in "$STATE_DIR"/daemon.json.2*; do [[ -f $f ]] && last=$f; done
  if [[ -n $last ]]; then
    install -m 0644 "$last" "$DAEMON_JSON"
    ok "restored $DAEMON_JSON from $last"
  elif [[ -f $STATE_DIR/daemon.json.absent ]]; then
    rm -f "$DAEMON_JSON" "$STATE_DIR/daemon.json.absent"
    ok "removed $DAEMON_JSON (there was none before)"
  fi
  log "Docker reads daemon.json at its next start; nothing restarted."
}

# ---------------------------------------------------------------- main ----

# The tests source this file with JERBOA_SOURCE_ONLY=1 to reach the helpers.
if [[ ${JERBOA_SOURCE_ONLY:-0} == 1 ]]; then return 0; fi

require_root
start_log
require_cmds docker logrotate journalctl python3 systemctl
mkdir -p "$STATE_DIR"
WORK=$(mktemp -d)
cleanup_add "rm -rf '$WORK'"

case $MODE in
  rollback) do_rollback; exit 0 ;;
  prune) do_prune; exit 0 ;;
esac

log "disk before: $(disk_free_mb /) MB free on /"
set_rollback "./ops_hygiene.sh --rollback    # removes logrotate/journald files, restores daemon.json"
do_logrotate
do_journald
do_docker_defaults
do_prune
step "Done"
log "disk after: $(disk_free_mb /) MB free on /"
log "Next: the OS upgrade + reboot, by hand (RUNBOOK.md, 'Manual: upgrade and reboot')."
print_rollback
