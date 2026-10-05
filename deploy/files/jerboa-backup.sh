#!/usr/bin/env bash
# jerboa-backup: Postgres dump + uploads snapshot with retention.
#
# Installed by deploy/backup.sh as /usr/local/sbin/jerboa-backup and run each
# night by jerboa-backup.timer. Safe to run by hand at any time:
#
#     systemctl start jerboa-backup      # full run; output: journalctl -u jerboa-backup
#     jerboa-backup --db-only            # only the database dump
#
# Settings: /etc/jerboa-backup.conf (override the path with JERBOA_BACKUP_CONF).
#
# Layout under $BACKUP_DIR (default /root/backups, mode 0700):
#   db/jerboa-db-<UTC ts>.dump (+ .sha256)   pg_dump custom format, one per run
#   uploads/<UTC ts>/chat_images, .../chat_emoijs
#                                            rsync snapshot. Unchanged files are
#                                            hard links into the previous snapshot,
#                                            so a night only costs the new uploads.
#   uploads/latest -> newest snapshot
#   LAST_SUCCESS                             UTC timestamp of the last clean run
#
# Retention: entries older than RETENTION_DAYS are deleted, judged by the
# timestamp in their name, but the newest KEEP_MIN (3) of each kind are always
# kept, so a timer that stopped running never empties the folder.
#
# Note on error handling: bash ignores `set -e` inside a function that is
# called as `f || ...`, so every step below checks its own exit status.

set -Eeuo pipefail
umask 077
export LC_ALL=C

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

load_conf() {
  CONF=${JERBOA_BACKUP_CONF:-/etc/jerboa-backup.conf}
  # shellcheck source=/dev/null
  source "$CONF"
  : "${DB_CONTAINER:?set DB_CONTAINER in $CONF}"
  : "${DB_USER:?set DB_USER in $CONF}"
  : "${DB_NAME:?set DB_NAME in $CONF}"
  : "${BACKUP_DIR:?set BACKUP_DIR in $CONF}"
  : "${RETENTION_DAYS:=14}"
  : "${UPLOADS_MODE:=snapshot}"
  : "${UPLOADS_DIRS:=}"
  : "${HEALTHCHECK_URL:=}"
  : "${KEEP_MIN:=3}"
  TS=${TS:-$(date -u +%Y%m%dT%H%M%SZ)}
  DB_DIR=$BACKUP_DIR/db
  UP_DIR=$BACKUP_DIR/uploads
}

ping_health() { # [suffix], e.g. /fail for healthchecks.io
  [[ -n $HEALTHCHECK_URL ]] || return 0
  curl -fsS -m 10 --retry 3 "${HEALTHCHECK_URL}${1:-}" >/dev/null 2>&1 || log "health ping failed (ignored)"
}

dump_db() {
  local name="jerboa-db-$TS.dump"
  local out="$DB_DIR/$name"
  log "pg_dump -Fc of database '$DB_NAME' as '$DB_USER' in container '$DB_CONTAINER'"
  if ! docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$out.partial"; then
    log "ERROR: pg_dump failed"; rm -f "$out.partial"; return 1
  fi
  # A dump that pg_restore cannot read back is not a backup.
  if ! docker exec -i "$DB_CONTAINER" pg_restore -l < "$out.partial" > /dev/null; then
    log "ERROR: pg_restore -l cannot read the new dump; keeping it as $out.unreadable"
    mv -f "$out.partial" "$out.unreadable"; return 1
  fi
  mv "$out.partial" "$out" || return 1
  (cd "$DB_DIR" && sha256sum "$name" > "$name.sha256") || return 1
  log "db dump ok: $out ($(du -h "$out" | cut -f1))"
}

need_mb_for_full_copy() {
  # shellcheck disable=SC2086  # UPLOADS_DIRS is a space-separated list of paths
  du -sm $UPLOADS_DIRS 2>/dev/null | awk '{s += $1} END {print int(s * 1.1) + 200}'
}

snapshot_uploads() {
  local dest="$UP_DIR/$TS" prev="" src name need free entry
  # Leftovers of an interrupted run. We hold the lock, so nothing else writes here.
  for entry in "$UP_DIR"/*.partial; do
    [[ -e $entry ]] && rm -rf -- "$entry"
  done
  for entry in "$UP_DIR"/2*; do
    [[ -d $entry && ! -L $entry ]] && prev=$entry   # glob is sorted, so the last one wins
  done
  free=$(df -Pm "$UP_DIR" | awk 'NR==2 {print $4}')
  if [[ -z $prev ]]; then need=$(need_mb_for_full_copy); else need=500; fi
  if (( free < need )); then
    log "ERROR: uploads snapshot needs ~${need} MB, only ${free} MB free; skipped"
    return 1
  fi
  mkdir -p "$dest.partial" || return 1
  for src in $UPLOADS_DIRS; do
    [[ -d $src ]] || { log "skip missing $src"; continue; }
    name=$(basename "$src")
    if ! rsync -a --delete ${prev:+--link-dest="$prev/$name/"} "$src/" "$dest.partial/$name/"; then
      log "ERROR: rsync of $src failed; partial snapshot left in $dest.partial"
      return 1
    fi
  done
  mv "$dest.partial" "$dest" || return 1
  ln -sfn "$TS" "$UP_DIR/latest" || return 1
  log "uploads snapshot ok: $dest (all snapshots together use $(du -sh "$UP_DIR" | cut -f1) on disk)"
}

tar_uploads() {
  local out="$UP_DIR/uploads-$TS.tar" need free d
  local -a rel=()
  need=$(need_mb_for_full_copy)
  free=$(df -Pm "$UP_DIR" | awk 'NR==2 {print $4}')
  if (( free < need )); then
    log "ERROR: uploads tarball needs ~${need} MB, only ${free} MB free; skipped"
    return 1
  fi
  for d in $UPLOADS_DIRS; do [[ -d $d ]] && rel+=("${d#/}"); done
  [[ ${#rel[@]} -gt 0 ]] || { log "ERROR: none of UPLOADS_DIRS exist"; return 1; }
  if ! tar -C / -cf "$out.partial" "${rel[@]}"; then
    log "ERROR: tar failed"; rm -f "$out.partial"; return 1
  fi
  mv "$out.partial" "$out" || return 1
  log "uploads tarball ok: $out ($(du -h "$out" | cut -f1))"
}

retention_cutoff() {
  date -u -d "-${RETENTION_DAYS} days" +%Y%m%dT%H%M%SZ 2>/dev/null ||
    date -u -v-"${RETENTION_DAYS}"d +%Y%m%dT%H%M%SZ   # BSD date, for local tests
}

# Delete <prefix><ts><suffix> entries in <dir> whose <ts> is older than the
# cutoff, always keeping the newest KEEP_MIN entries.
prune_by_name() { # <dir> <prefix> <suffix>
  local dir=$1 prefix=$2 suffix=$3 cutoff i n entry ts path
  local -a all=()
  cutoff=$(retention_cutoff)
  for path in "$dir/$prefix"2*"$suffix"; do
    [[ -e $path && ! -L $path ]] || continue
    [[ $path == *.sha256 || $path == *.partial ]] && continue
    all+=("$(basename "$path")")
  done
  n=${#all[@]}
  for (( i = 0; i < n - KEEP_MIN; i++ )); do
    entry=${all[$i]}
    ts=${entry#"$prefix"}
    ts=${ts%"$suffix"}
    if [[ $ts < $cutoff ]]; then
      rm -rf -- "${dir:?}/$entry" "${dir:?}/$entry.sha256"
      log "pruned $dir/$entry (older than $RETENTION_DAYS days)"
    fi
  done
}

main() {
  local db_only=0 rc=0
  [[ ${1:-} == --db-only ]] && db_only=1
  load_conf
  mkdir -p "$DB_DIR" "$UP_DIR"
  chmod 700 "$BACKUP_DIR" "$DB_DIR" "$UP_DIR"

  # One run at a time.
  exec 9>"$BACKUP_DIR/.lock"
  flock -n 9 || { log "another jerboa-backup is running; exiting"; exit 1; }

  trap 'log "FAILED near line ${LINENO}: ${BASH_COMMAND}"; ping_health /fail' ERR

  dump_db || rc=1

  if [[ $db_only == 0 ]]; then
    case $UPLOADS_MODE in
      snapshot) snapshot_uploads || rc=1 ;;
      tar)      tar_uploads || rc=1 ;;
      off)      log "uploads backup disabled (UPLOADS_MODE=off)" ;;
      *)        log "ERROR: unknown UPLOADS_MODE=$UPLOADS_MODE"; rc=1 ;;
    esac
    prune_by_name "$DB_DIR" jerboa-db- .dump
    prune_by_name "$UP_DIR" "" ""
    prune_by_name "$UP_DIR" uploads- .tar
  fi

  if [[ $rc == 0 ]]; then
    printf '%s\n' "$TS" > "$BACKUP_DIR/LAST_SUCCESS"
    ping_health
    log "backup finished OK"
  else
    ping_health /fail
    log "backup finished WITH ERRORS (exit 1)"
  fi
  return "$rc"
}

# Tests source this file with JERBOA_BACKUP_SOURCE_ONLY=1 to call functions.
if [[ ${JERBOA_BACKUP_SOURCE_ONLY:-0} != 1 ]]; then
  main "$@"
fi
