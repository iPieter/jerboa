#!/usr/bin/env bash
# Phase 1: backups. No downtime; does not change the app or the database.
#
#   ./backup.sh              immediate DB dump, then install the nightly backup
#   ./backup.sh --full-now   also run the full nightly job right away (the first
#                            uploads snapshot copies ~2.3 GB: a few minutes of IO)
#   ./backup.sh --uninstall  remove the nightly job (rollback); keeps /root/backups
#   ./backup.sh --yes        do not ask questions
#
# Steps
#   1. Find the running Postgres container (or take it from /etc/jerboa-backup.conf).
#   2. pg_dump -Fc to /root/backups/db/jerboa-db-<UTC ts>.dump, read it back with
#      pg_restore -l, write a .sha256 next to it.
#   3. Install /usr/local/sbin/jerboa-backup and jerboa-backup.{service,timer}:
#      nightly at ~03:15 UTC, DB dump + uploads snapshot, 14-day retention.
#
# Safe to re-run. It never overwrites /etc/jerboa-backup.conf once that exists
# (migrate_db.sh points it at the new database later).

PHASE=backup
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FULL_NOW=0
UNINSTALL=0
for arg in "$@"; do
  case $arg in
    --full-now) FULL_NOW=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage_and_exit ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

JOB=/usr/local/sbin/jerboa-backup
UNIT_DIR=/etc/systemd/system

uninstall() {
  step "Removing the nightly backup job (the backups in $BACKUP_DIR stay)"
  systemctl disable --now jerboa-backup.timer 2>/dev/null || true
  rm -f "$UNIT_DIR/jerboa-backup.timer" "$UNIT_DIR/jerboa-backup.service" "$JOB"
  systemctl daemon-reload
  ok "removed timer, service and $JOB"
  log "$BACKUP_CONF is kept; delete it by hand if you want it gone."
}

render_conf() { # <db_container> <db_user> <db_name>
  sed -e "s|@DB_CONTAINER@|$1|" -e "s|@DB_USER@|$2|" -e "s|@DB_NAME@|$3|" \
      -e "s|@BACKUP_DIR@|$BACKUP_DIR|" -e "s|@UPLOADS_DIR@|$UPLOADS_DIR|" \
      -e "s|@EMOJIS_DIR@|$EMOJIS_DIR|" "$SCRIPT_DIR/files/jerboa-backup.conf"
}

# The tests source this file with JERBOA_SOURCE_ONLY=1 to reach the helpers.
if [[ ${JERBOA_SOURCE_ONLY:-0} == 1 ]]; then return 0; fi

require_root
start_log

if [[ $UNINSTALL == 1 ]]; then
  uninstall
  exit 0
fi

require_cmds docker rsync flock sha256sum systemctl

# ------------------------------------------------------------ pre-flight ----
step "Pre-flight"
db_container=""
db_user=""
db_name=""
conf_stale=0
if [[ -f $BACKUP_CONF ]]; then
  db_container=$(sed -n 's/^DB_CONTAINER=//p' "$BACKUP_CONF")
  db_user=$(sed -n 's/^DB_USER=//p' "$BACKUP_CONF")
  db_name=$(sed -n 's/^DB_NAME=//p' "$BACKUP_CONF")
  if container_running "$db_container"; then
    ok "using $BACKUP_CONF: container $db_container"
  else
    warn "$BACKUP_CONF names '$db_container', which is not running; detecting instead"
    db_container=""
    conf_stale=1
  fi
fi
if [[ -z $db_container ]]; then
  mapfile -t pgs < <(find_running_pg_containers)
  if [[ ${#pgs[@]} -ne 1 ]]; then
    die "Expected exactly one running Postgres container, found ${#pgs[@]}: ${pgs[*]:-none}."
  fi
  db_container=${pgs[0]}
  if [[ $db_container == "$DB_CONTAINER_NEW" ]]; then
    db_user=pgadmin; db_name=jerboa        # after migrate_db.sh
  else
    db_user=postgres; db_name=postgres     # the original container
  fi
fi
ok "database: container=$db_container user=$db_user db=$db_name"

if ! docker exec "$db_container" psql -U "$db_user" -d "$db_name" -Atc 'select 1' >/dev/null; then
  die "cannot run psql in $db_container as $db_user (local socket)."
fi
db_size=$(docker exec "$db_container" psql -U "$db_user" -d "$db_name" -Atc \
  "select pg_size_pretty(pg_database_size(current_database()))")
ok "database '$db_name' is $db_size"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
require_disk_mb "$BACKUP_DIR" 500 "database dumps"

# ------------------------------------------------------- immediate dump ----
step "Writing $BACKUP_CONF (only if missing or pointing at a stopped container)"
if [[ -f $BACKUP_CONF && $conf_stale == 1 ]]; then
  set_backup_target "$db_container" "$db_user" "$db_name"
elif [[ -f $BACKUP_CONF ]]; then
  ok "exists, left alone"
else
  (umask 077; render_conf "$db_container" "$db_user" "$db_name" > "$BACKUP_CONF")
  ok "created $BACKUP_CONF"
fi

step "Immediate database dump"
JERBOA_BACKUP_CONF=$BACKUP_CONF bash "$SCRIPT_DIR/files/jerboa-backup.sh" --db-only
dump=$(find "$BACKUP_DIR/db" -maxdepth 1 -name 'jerboa-db-*.dump' | sort | tail -n1)
[[ -n $dump ]] || die "no dump file found in $BACKUP_DIR/db"
ok "dump: $dump ($(du -h "$dump" | cut -f1)), sha256 $(cut -c1-16 "$dump.sha256")..."
log "Tables in the dump: $(docker exec -i "$db_container" pg_restore -l < "$dump" | grep -c ' TABLE DATA ')"

# ------------------------------------------------------- nightly backup ----
step "Installing the nightly backup"
set_rollback "$SCRIPT_DIR/backup.sh --uninstall      # removes timer + job, keeps $BACKUP_DIR"
install -m 0700 -o root -g root "$SCRIPT_DIR/files/jerboa-backup.sh" "$JOB"
install -m 0644 -o root -g root "$SCRIPT_DIR/files/systemd/jerboa-backup.service" "$UNIT_DIR/jerboa-backup.service"
install -m 0644 -o root -g root "$SCRIPT_DIR/files/systemd/jerboa-backup.timer" "$UNIT_DIR/jerboa-backup.timer"
systemctl daemon-reload
systemctl enable --now jerboa-backup.timer >/dev/null 2>&1
systemctl is-active --quiet jerboa-backup.timer || die "jerboa-backup.timer is not active"
ok "jerboa-backup.timer is active:"
systemctl list-timers jerboa-backup.timer --no-pager | sed 's/^/    /'

uploads_mb=$(du -sm "$UPLOADS_DIR" "$EMOJIS_DIR" 2>/dev/null | awk '{s += $1} END {print s + 0}')
if [[ $FULL_NOW == 1 ]] || ask_yn "Run the full job now (first uploads snapshot copies ~${uploads_mb} MB)?" n; then
  step "Running the full backup job now"
  require_disk_mb "$BACKUP_DIR" $(( uploads_mb * 11 / 10 + 200 )) "first uploads snapshot"
  if systemctl start jerboa-backup.service; then
    ok "full backup done"
  else
    warn "full backup reported errors"
  fi
  journalctl -u jerboa-backup.service -n 15 --no-pager -o cat | sed 's/^/    /'
else
  log "Skipped; the first uploads snapshot will be taken by tonight's run."
fi

# -------------------------------------------------------------- summary ----
step "Done"
cat <<EOF
  Immediate dump : $dump
  Nightly job    : $JOB (config $BACKUP_CONF)
  Check later    : systemctl list-timers jerboa-backup.timer
                   journalctl -u jerboa-backup --since yesterday
                   cat $BACKUP_DIR/LAST_SUCCESS

  Restore test (read-only, lists the contents):
    docker exec -i $db_container pg_restore -l < $dump | head

  Off-box copies: nothing leaves this server yet. Pick one (see RUNBOOK.md):
    a) pull from your laptop, no credentials on the server:
         rsync -av  root@$PUBLIC_HOST:$BACKUP_DIR/db/ ~/jerboa-backups/db/
         rsync -avH root@$PUBLIC_HOST:$BACKUP_DIR/uploads/latest/ ~/jerboa-backups/uploads/
    b) DigitalOcean droplet backups (weekly disk images): enable in the control panel
    c) restic/rclone to object storage from the timer, with an append-only key
EOF
print_rollback
