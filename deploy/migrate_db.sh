#!/usr/bin/env bash
# Phase 4: move the database to a fresh Postgres 16 container. 2-5 min downtime.
#
#   ./migrate_db.sh --rehearse   dry run, NO downtime: restore a live dump into a
#                                throwaway PG16 on 127.0.0.1:55432, compare counts and
#                                let the current app image query it as the new role
#   ./migrate_db.sh              the real migration (asks before downtime starts)
#   ./migrate_db.sh --rollback   back to the old container (dumps PG16 first)
#   ./migrate_db.sh --status
#   options:
#     --legacy-role-name         name the app role "postgres" (still NOT a superuser)
#                                for backend code that hardcodes user="postgres"
#     --accept-unknown-objects   restore even if the old DB holds non-app objects
#     --yes                      do not ask questions
#
# Why: the old container (postgres:latest from 2019, really PG 11.5) was
# compromised. Neither its container layer nor its data directory is trusted.
# We take a logical dump, restore it into a brand-new cluster as a
# non-superuser, and never start the old container again except for rollback.
#
# Steps
#   0. Pre-flight, no downtime: find the old DB and app containers, check the app
#      code can use another DB user, audit the old DB for non-app objects, pull
#      postgres:16, check disk and RAM.
#   1. Stop the app (downtime starts). Dump the old DB with a clean pg_dump 16;
#      record exact row counts and sequence values.
#   2. Stop the old Postgres with a fast shutdown to free RAM. Not removed.
#   3. Start postgres:16 as jerboa-db: --network host, listen_addresses=localhost,
#      data in /root/pgdata16, scram-sha-256 for every TCP connection (the image's
#      default 127.0.0.1 "trust" lines are not created), superuser "pgadmin".
#   4. Create role jerboa (LOGIN, no superuser/createdb/createrole) with a
#      generated password, and database jerboa owned by it. Restore with
#      --no-owner --no-privileges --role=jerboa in one transaction.
#   5. Compare row counts and sequence values with step 1.
#   6. Put db_user/db_name/db_pass/PGDATABASE into /root/jerboa.env, recreate the
#      app container from the same image (env files are read at creation),
#      health check. Downtime ends.
#   7. Point the nightly backup at jerboa-db and take a first dump of it.
#   A failure in steps 1-6 rolls back automatically to the old database.
#
# Backend contract: the app must read the DB user and database name from the
# env vars db_user and db_name (defaults "postgres"), like it reads db_pass.
# The pre-flight checks for that. Until the backend has it, use
# --legacy-role-name (see RUNBOOK.md).

PHASE=migrate_db
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

# Names of the env vars the backend reads. Change here if the backend branch
# picks different ones.
: "${DB_USER_VAR:=db_user}"
: "${DB_NAME_VAR:=db_name}"
APP_DB=jerboa
ADMIN_USER=pgadmin
ADMIN_ENV=/root/jerboa-db-admin.env
REHEARSAL_PORT=55432
REHEARSAL_CONTAINER=jerboa-db-rehearsal
# Every table the migrations in migrations/ create, plus yoyo's own tables.
APP_TABLES="users active_logins messages files emojis channels channels_users _yoyo_migration _yoyo_log _yoyo_version yoyo_lock"

MODE=migrate
APP_ROLE=jerboa
ACCEPT_UNKNOWN=0
for arg in "$@"; do
  case $arg in
    --rehearse) MODE=rehearse ;;
    --rollback) MODE=rollback ;;
    --status) MODE=status ;;
    --legacy-role-name) APP_ROLE=postgres ;;
    --accept-unknown-objects) ACCEPT_UNKNOWN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage_and_exit ;;
    *) die "unknown argument: $arg (see --help)" ;;
  esac
done

# ------------------------------------------------------------- helpers ----

psql_old() { docker exec -i "$OLD_DB" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -At "$@"; }
# psql as the superuser in the new cluster ($NEW_C, port $NEW_PORT); the
# database is $NEW_DBNAME if set, else the app database.
psql_new() {
  docker exec -i "$NEW_C" psql -X -U "$ADMIN_USER" -p "$NEW_PORT" -d "${NEW_DBNAME:-$APP_DB}" -v ON_ERROR_STOP=1 -At "$@"
}

# Row count per table and last value per sequence, one "name|value" per line.
# The first query writes one count(*) statement per table and psql's \gexec
# runs them (psql >= 9.6, so the old PG 11 client works too).
COUNTS_SQL="
select format('select %L || ''|'' || count(*) from %I.%I', c.relname, n.nspname, c.relname)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind = 'r' and n.nspname = 'public'
 order by c.relname
\\gexec
select 'seq:' || sequencename || '|' || coalesce(last_value::text, 'unused')
  from pg_sequences where schemaname = 'public' order by sequencename;"

# Anything in the old database that the app's migrations did not create.
audit_sql() {
  local tables
  tables="'{$(tr ' ' ',' <<<"$APP_TABLES")}'"
  cat <<SQL
select 'relation ' || n.nspname || '.' || c.relname || ' (relkind ' || c.relkind::text || ')'
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where c.relkind in ('r','p','v','m','f')
   and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname !~ '^pg_toast'
   and not (n.nspname = 'public' and c.relkind = 'r' and c.relname = any ($tables::text[]))
union all select 'function ' || n.nspname || '.' || p.proname
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname not in ('pg_catalog', 'information_schema')
union all select 'extension ' || extname from pg_extension where extname <> 'plpgsql'
union all select 'event trigger ' || evtname from pg_event_trigger
union all select 'trigger ' || tgname || ' on ' || tgrelid::regclass from pg_trigger where not tgisinternal
union all select 'schema ' || nspname from pg_namespace
 where nspname !~ '^pg_' and nspname not in ('information_schema', 'public')
union all select 'large objects: ' || count(*) from pg_largeobject_metadata having count(*) > 0
union all select 'extra role ' || rolname || case when rolsuper then ' (SUPERUSER)' else '' end
  from pg_roles where rolname !~ '^pg_' and rolname <> 'postgres';
SQL
}

write_admin_env() { # <path> <password>
  local tmp
  tmp=$(mktemp "$(dirname "$1")/.jerboa-db-admin.XXXXXX")
  chmod 600 "$tmp"
  {
    printf '# Postgres 16 bootstrap settings for the jerboa-db container (docker --env-file).\n'
    printf '# Only used by the first start (initdb). %s is the superuser; its password\n' "$ADMIN_USER"
    printf '# is only needed for TCP logins, local admin work goes through docker exec.\n'
    printf 'POSTGRES_USER=%s\n' "$ADMIN_USER"
    printf 'POSTGRES_PASSWORD=%s\n' "$2"
    printf 'POSTGRES_DB=postgres\n'
    # initdb's own default is "trust" for local and 127.0.0.1 connections; with
    # --network host that would let any process on the droplet in as superuser.
    printf 'POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=trust\n'
  } > "$tmp"
  mv -f "$tmp" "$1"
}

# Start a PG16 container. Rehearsals get a throwaway one on another port.
start_pg16() { # <name> <port> <data-mount-or-empty> <admin-env> <shared_buffers> <restart-policy>
  local -a mount=()
  [[ -n $3 ]] && mount=(-v "$3:/var/lib/postgresql/data")
  docker run -d --name "$1" --label jerboa.role=db \
    --network host --restart "$6" \
    --log-driver json-file --log-opt max-size=10m --log-opt max-file=3 \
    --shm-size=128m \
    --env-file "$4" \
    ${mount[@]+"${mount[@]}"} \
    "$PG_IMAGE" \
    -c listen_addresses=localhost -c port="$2" \
    -c password_encryption=scram-sha-256 \
    -c max_connections=20 -c shared_buffers="$5" >/dev/null
}

# Check the new cluster is locked down the way we want.
verify_pg16_hardening() { # uses NEW_C / NEW_PORT
  local hba bad listen enc ver
  hba=$(docker exec "$NEW_C" sh -c 'grep -vE "^[[:space:]]*(#|$)" "$PGDATA/pg_hba.conf"')
  printf '%s\n' "$hba" | sed 's/^/    pg_hba: /'
  bad=$(printf '%s\n' "$hba" | awk '$1 ~ /^host/ && $NF != "scram-sha-256"')
  [[ -z $bad ]] || { warn "pg_hba has TCP lines without scram-sha-256: $bad"; return 1; }
  listen=$(NEW_DBNAME=postgres psql_new -c 'show listen_addresses')
  enc=$(NEW_DBNAME=postgres psql_new -c 'show password_encryption')
  ver=$(NEW_DBNAME=postgres psql_new -c 'show server_version')
  [[ $listen == localhost ]] || { warn "listen_addresses is '$listen'"; return 1; }
  [[ $enc == scram-sha-256 ]] || { warn "password_encryption is '$enc'"; return 1; }
  if ss -ltn "( sport = :$NEW_PORT )" | awk 'NR>1 {print $4}' | grep -vqE '^(127\.0\.0\.1|\[::1\]):'; then
    warn "something listens on port $NEW_PORT beyond loopback:"
    ss -ltn "( sport = :$NEW_PORT )" >&2
    return 1
  fi
  ok "PG $ver: listen_addresses=localhost, scram-sha-256 on every TCP line, loopback only"
}

# Create the app role and database. The password reaches psql through the
# environment (docker exec -e NAME without a value copies it from ours) and
# psql's \getenv, so it is never part of any command line.
create_role_and_db() { # uses NEW_C / NEW_PORT / APP_ROLE / APP_DB_PASS
  JERBOA_APP_DB_PASS=$APP_DB_PASS docker exec -i -e JERBOA_APP_DB_PASS "$NEW_C" \
    psql -X -q -U "$ADMIN_USER" -p "$NEW_PORT" -d postgres -v ON_ERROR_STOP=1 \
         -v app_role="$APP_ROLE" -v app_db="$APP_DB" <<'SQL'
\getenv app_pw JERBOA_APP_DB_PASS
CREATE ROLE :"app_role" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS
  CONNECTION LIMIT 10 PASSWORD :'app_pw';
CREATE DATABASE :"app_db" OWNER :"app_role";
REVOKE ALL ON DATABASE :"app_db" FROM PUBLIC;
REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;
REVOKE CONNECT ON DATABASE template1 FROM PUBLIC;
SQL
  ok "role '$APP_ROLE' (LOGIN, NOSUPERUSER, NOCREATEDB, NOCREATEROLE) and database '$APP_DB' owned by it"
}

restore_dump() { # <dump> ; uses NEW_C / NEW_PORT / APP_ROLE
  docker exec -i "$NEW_C" pg_restore -U "$ADMIN_USER" -p "$NEW_PORT" -d "$APP_DB" \
    --no-owner --no-privileges --role="$APP_ROLE" --single-transaction --exit-on-error < "$1"
  psql_new -c 'ANALYZE' >/dev/null
  ok "restored $(basename "$1") into '$APP_DB' as '$APP_ROLE' (single transaction)"
}

check_app_role_owns_everything() {
  local others
  others=$(psql_new -c "select c.relname || ' owned by ' || pg_get_userbyid(c.relowner)
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and pg_get_userbyid(c.relowner) <> '$APP_ROLE'")
  [[ -z $others ]] || { warn "objects not owned by $APP_ROLE: $others"; return 1; }
  ok "every object in public is owned by $APP_ROLE"
}

pull_pg_image() {
  log "docker pull $PG_IMAGE (no downtime) ..."
  docker pull -q "$PG_IMAGE" >/dev/null
  PG_DIGEST=$(docker image inspect -f '{{index .RepoDigests 0}}' "$PG_IMAGE" 2>/dev/null || echo "?")
  ok "$PG_IMAGE = $PG_DIGEST"
}

dump_old_db() { # <out-file>
  local out=$1 name
  name=$(basename "$out")
  mkdir -p "$(dirname "$out")"
  if docker run --rm --network host -v "$(dirname "$out"):/out" "$PG_IMAGE" \
       pg_dump -w -h 127.0.0.1 -p 5432 -U postgres -d postgres -Fc -f "/out/$name.partial"; then
    ok "dumped with a clean pg_dump from $PG_IMAGE (not the old container's binaries)"
  else
    warn "the clean client could not log in over 127.0.0.1; using pg_dump inside $OLD_DB"
    docker exec "$OLD_DB" pg_dump -U postgres -d postgres -Fc > "$out.partial"
  fi
  docker run --rm -i "$PG_IMAGE" pg_restore -l < "$out.partial" > "$WORK/toc"
  mv "$out.partial" "$out"
  chmod 600 "$out"
  ok "dump $out ($(du -h "$out" | cut -f1)), $(grep -c ' TABLE DATA ' "$WORK/toc") tables with data"
}

app_supports_db_user() { # <app container>
  docker exec "$1" grep -q "$DB_USER_VAR" /chat_app/app/database.py 2>/dev/null
}

# Move a container's name out of the way (keeps the container) and start a new
# app container with the current $ENV_FILE.
recreate_app() { # <name> <image> <tag>
  if container_exists "$1"; then
    docker stop -t 20 "$1" >/dev/null 2>&1 || true
    docker rename "$1" "$1-$3-$(ts_utc)" || return 1
  fi
  wait_port_free "$APP_PORT" || { warn "port $APP_PORT still in use"; return 1; }
  run_app_container "$1" "$2" "$ENV_FILE"
}

common_preflight() {
  require_root
  require_cmds docker openssl python3 curl ss
  mkdir -p "$STATE_DIR"
  WORK=$(mktemp -d)
  cleanup_add "rm -rf '$WORK'"

  step "Pre-flight"
  mapfile -t pgs < <(find_running_pg_containers | grep -vx -e "$DB_CONTAINER_NEW" -e "$REHEARSAL_CONTAINER" || true)
  (( ${#pgs[@]} == 1 )) || die "expected one running old Postgres container, found ${#pgs[@]}: ${pgs[*]:-none}"
  OLD_DB=${pgs[0]}
  OLD_DATA=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{.Source}}{{end}}{{end}}' "$OLD_DB")
  ok "old database: $OLD_DB ($(container_image "$OLD_DB"), data $OLD_DATA, PG $(psql_old -c 'show server_version'))"

  mapfile -t apps < <(find_running_app_containers)
  (( ${#apps[@]} == 1 )) || die "expected one running backend container, found ${#apps[@]}: ${apps[*]:-none}"
  APP=${apps[0]}
  APP_IMAGE=$(container_image "$APP")
  container_env_names "$APP" | grep -qx flask_secret ||
    die "$APP was not started by deploy_app.sh (no --env-file). Run phase 2 first."
  ok "backend: $APP ($APP_IMAGE), started with --env-file"
  [[ -f $ENV_FILE ]] || die "$ENV_FILE is missing; run deploy_app.sh first"

  if app_supports_db_user "$APP"; then
    ok "backend code reads $DB_USER_VAR from the environment"
  elif [[ $APP_ROLE == postgres ]]; then
    warn "backend code hardcodes user=\"postgres\"; --legacy-role-name: the app role in the new"
    warn "cluster is called 'postgres' but is NOT a superuser (the superuser is '$ADMIN_USER')."
  else
    die "the running backend hardcodes user=\"postgres\" (app/database.py has no $DB_USER_VAR).
      Either deploy a backend that reads $DB_USER_VAR/$DB_NAME_VAR (see RUNBOOK.md), or
      re-run with --legacy-role-name to give the non-superuser app role the name 'postgres'."
  fi

  local listen
  listen=$(psql_old -c 'show listen_addresses')
  [[ $listen == localhost || $listen == 127.0.0.1 ]] ||
    warn "old Postgres still has listen_addresses='$listen' (containment not applied?)"

  step "Audit: objects in the old database that the app did not create"
  local unknown
  unknown=$(audit_sql | psql_old)
  if [[ -z $unknown ]]; then
    ok "only the app's tables and sequences (and yoyo's) exist; no functions, triggers or extra roles"
  else
    printf '%s\n' "$unknown" | sed 's/^/    /'
    if [[ $ACCEPT_UNKNOWN == 1 ]]; then
      warn "--accept-unknown-objects: they will be restored too (as the non-superuser app role)"
    else
      die "unexpected objects (attacker leftovers?). Inspect them in the old DB; drop them or re-run with --accept-unknown-objects."
    fi
  fi

  pull_pg_image
}

# ---------------------------------------------------------------- status ----

show_status() {
  require_root
  step "Database containers"
  docker ps -a --format '  {{.Names}}\t{{.Image}}\t{{.Status}}' | grep -E 'postgres|jerboa-db' || true
  log "migrated: $(state_get db.migrated || true)   old container: $(state_get db.old_container)"
  local app
  app=$(find_running_app_containers | head -n1)
  if [[ -n $app ]]; then
    log "backend $app env vars: $(container_env_names "$app" | grep -E "^(db_|PG)" | tr '\n' ' ')"
  fi
  if container_running "$DB_CONTAINER_NEW"; then
    NEW_C=$DB_CONTAINER_NEW
    NEW_PORT=5432
    verify_pg16_hardening || true
  fi
}

# -------------------------------------------------------------- rehearse ----

rehearse() {
  start_log
  common_preflight
  (( $(mem_available_mb) >= 250 )) || die "need ~250 MB free RAM for a rehearsal, have $(mem_available_mb) MB"
  ! port_listening "$REHEARSAL_PORT" || die "port $REHEARSAL_PORT is in use"
  if container_exists "$REHEARSAL_CONTAINER"; then
    docker rm -f -v "$REHEARSAL_CONTAINER" >/dev/null
  fi

  NEW_C=$REHEARSAL_CONTAINER
  NEW_PORT=$REHEARSAL_PORT
  APP_DB_PASS=$(gen_secret)
  local admin_env="$WORK/admin.env" app_env="$WORK/app.env" dump="$WORK/rehearsal.dump"
  write_admin_env "$admin_env" "$(gen_secret)"

  step "Dumping the live database (app keeps running)"
  dump_old_db "$dump"
  psql_old <<<"$COUNTS_SQL" > "$WORK/counts.old"

  step "Throwaway PG16 on 127.0.0.1:$NEW_PORT"
  cleanup_add "docker rm -f -v '$REHEARSAL_CONTAINER'"
  start_pg16 "$NEW_C" "$NEW_PORT" "" "$admin_env" 32MB no
  wait_pg_ready "$NEW_C" "$ADMIN_USER" 120 "$NEW_PORT" || { show_container_logs "$NEW_C"; die "rehearsal PG16 did not start"; }
  verify_pg16_hardening
  create_role_and_db
  restore_dump "$dump"
  check_app_role_owns_everything

  step "Row counts: live old DB vs rehearsal copy"
  psql_new <<<"$COUNTS_SQL" > "$WORK/counts.new"
  if diff -u "$WORK/counts.old" "$WORK/counts.new" > "$WORK/counts.diff"; then
    ok "identical ($(grep -vc '^seq:' "$WORK/counts.new") tables, $(grep -c '^seq:' "$WORK/counts.new") sequences)"
  else
    warn "differences (normal if people were chatting during the dump):"
    sed 's/^/    /' "$WORK/counts.diff"
  fi

  step "Backend image $APP_IMAGE against the copy, as role '$APP_ROLE'"
  cp "$ENV_FILE" "$app_env"
  chmod 600 "$app_env"
  env_set "$DB_USER_VAR" "$APP_ROLE" "$app_env"
  env_set "$DB_NAME_VAR" "$APP_DB" "$app_env"
  env_set PGDATABASE "$APP_DB" "$app_env"
  env_set db_pass "$APP_DB_PASS" "$app_env"
  env_set PGPORT "$NEW_PORT" "$app_env"   # libpq default port; the app passes none
  if timeout 180 docker run --rm --network host --env-file "$app_env" --entrypoint "" "$APP_IMAGE" \
       pipenv run python -c 'import app.server as s; print("QUERY_OK users =", s.database.sql_to_dict("select count(*) as n from users")[0]["n"])' \
       > "$WORK/smoke.out" 2>&1 && grep -q QUERY_OK "$WORK/smoke.out"; then
    ok "$(grep QUERY_OK "$WORK/smoke.out")"
  else
    tail -n 20 "$WORK/smoke.out" | sed 's/^/  | /'
    die "the backend could not query the copy as '$APP_ROLE' (see above)"
  fi

  step "Rehearsal passed"
  log "The throwaway container and its data are removed on exit. Nothing else changed."
  log "Real run: ./migrate_db.sh$([[ $APP_ROLE == postgres ]] && echo ' --legacy-role-name')"
}

# --------------------------------------------------------------- migrate ----

STAGE=none   # how far the real migration got; drives the automatic rollback

auto_rollback() {
  trap - ERR
  set +e
  step "Automatic rollback (got as far as: $STAGE)"
  if [[ $STAGE == app_started ]]; then
    show_container_logs "$APP" 60
  fi
  if [[ $STAGE == app_started || $STAGE == env_switched ]]; then
    cp -p "$ENV_BACKUP" "$ENV_FILE" && chmod 600 "$ENV_FILE" && ok "restored $ENV_FILE from $ENV_BACKUP"
  fi
  if container_exists "$DB_CONTAINER_NEW"; then
    docker stop -t 30 "$DB_CONTAINER_NEW" >/dev/null 2>&1
    docker update --restart=no "$DB_CONTAINER_NEW" >/dev/null 2>&1
    docker rename "$DB_CONTAINER_NEW" "$DB_CONTAINER_NEW-failed-$TS" && ok "kept failed PG16 as $DB_CONTAINER_NEW-failed-$TS"
  fi
  if [[ -d $PGDATA_NEW ]]; then
    mv "$PGDATA_NEW" "$PGDATA_NEW.failed-$TS" && ok "moved $PGDATA_NEW to $PGDATA_NEW.failed-$TS"
  fi
  if [[ $STAGE != none && $STAGE != app_stopped ]] || ! container_running "$OLD_DB"; then
    docker start "$OLD_DB" >/dev/null && wait_pg_ready "$OLD_DB" postgres 90
  fi
  if [[ $STAGE == app_started || $STAGE == env_switched ]]; then
    recreate_app "$APP" "$APP_IMAGE" pg16-failed || warn "could not recreate $APP"
  else
    docker start "$APP" >/dev/null 2>&1
  fi
  if app_health_check 90; then
    ok "back on the old database; the backend is healthy"
  else
    warn "the backend is NOT healthy after the rollback. Check: docker logs --tail 100 $APP"
  fi
  printf '\nThe pre-migration dump stays at %s\n' "${DUMP:-<none>}"
  exit 1
}

migrate() {
  start_log
  if container_exists "$DB_CONTAINER_NEW"; then
    if container_running "$DB_CONTAINER_NEW" && [[ -n $(state_get db.migrated) ]]; then
      ok "already migrated on $(state_get db.migrated); $DB_CONTAINER_NEW is running. Nothing to do."
      exit 0
    fi
    die "a container named $DB_CONTAINER_NEW exists but the migration is not recorded. Inspect it (docker logs $DB_CONTAINER_NEW) and remove it before retrying."
  fi
  if [[ -e $PGDATA_NEW ]] && [[ -n $(ls -A "$PGDATA_NEW" 2>/dev/null) ]]; then
    die "$PGDATA_NEW exists and is not empty. Move it aside before retrying."
  fi
  common_preflight
  require_disk_mb /root 1500 "dump + new data dir"
  log "memory available: $(mem_available_mb) MB (the old Postgres is stopped before PG16 starts)"

  TS=$(ts_utc)
  DUMP="$BACKUP_DIR/db/premigrate-pg11-$TS.dump"
  NEW_C=$DB_CONTAINER_NEW
  NEW_PORT=5432
  APP_DB_PASS=$(gen_secret)

  step "Plan"
  cat <<EOF
  1. stop backend $APP                                  <- downtime starts
  2. dump $OLD_DB to $DUMP, record row counts
  3. stop $OLD_DB (fast shutdown; kept, not removed)
  4. start $DB_CONTAINER_NEW ($PG_IMAGE) on 127.0.0.1:5432, data $PGDATA_NEW
  5. role '$APP_ROLE' + database '$APP_DB', restore, compare counts
  6. update $ENV_FILE, recreate $APP from $APP_IMAGE, health check   <- downtime ends
  Expected downtime: 2-5 minutes. Any failure rolls back to $OLD_DB automatically.
EOF
  confirm "Start the migration (the chat goes down now)?" migrate || die "aborted; nothing changed"

  # Only at the top level: see the note on _on_err in lib.sh.
  trap '(( BASH_SUBSHELL == 0 )) && { _on_err; auto_rollback; }' ERR

  step "1. Stopping the backend"
  docker stop -t 20 "$APP" >/dev/null
  STAGE=app_stopped
  ok "stopped $APP"

  step "2. Final dump of the old database"
  dump_old_db "$DUMP"
  psql_old <<<"$COUNTS_SQL" > "$WORK/counts.old"
  ok "recorded $(grep -vc '^seq:' "$WORK/counts.old") table counts and $(grep -c '^seq:' "$WORK/counts.old") sequences"

  step "3. Stopping the old Postgres ($OLD_DB)"
  state_set db.old_container "$OLD_DB"
  stop_pg_container "$OLD_DB"
  docker update --restart=no "$OLD_DB" >/dev/null
  STAGE=old_db_stopped
  wait_port_free 5432 || { warn "port 5432 still busy"; auto_rollback; }

  step "4. Starting $DB_CONTAINER_NEW"
  write_admin_env "$ADMIN_ENV" "$(gen_secret)"
  mkdir -p "$PGDATA_NEW"
  chmod 700 "$PGDATA_NEW"
  start_pg16 "$NEW_C" 5432 "$PGDATA_NEW" "$ADMIN_ENV" 128MB unless-stopped
  STAGE=new_db_started
  wait_pg_ready "$NEW_C" "$ADMIN_USER" 120 5432 || { show_container_logs "$NEW_C"; auto_rollback; }
  verify_pg16_hardening || auto_rollback

  step "5. Role, database, restore, verification"
  create_role_and_db
  restore_dump "$DUMP"
  check_app_role_owns_everything || auto_rollback
  psql_new <<<"$COUNTS_SQL" > "$WORK/counts.new"
  if diff -u "$WORK/counts.old" "$WORK/counts.new"; then
    ok "row counts and sequence values match exactly"
  else
    warn "row counts differ (diff above)"
    auto_rollback
  fi

  step "6. Switching the backend to $DB_CONTAINER_NEW"
  ENV_BACKUP=$(backup_secret_file "$ENV_FILE" pre-pg16)
  state_set db.env_backup "$ENV_BACKUP"
  STAGE=env_switched
  env_set "$DB_USER_VAR" "$APP_ROLE" "$ENV_FILE"
  env_set "$DB_NAME_VAR" "$APP_DB" "$ENV_FILE"
  env_set PGDATABASE "$APP_DB" "$ENV_FILE"   # libpq fallback when the code passes no dbname
  env_set db_pass "$APP_DB_PASS" "$ENV_FILE"
  ok "$ENV_FILE: $DB_USER_VAR, $DB_NAME_VAR, PGDATABASE, db_pass updated (old copy: $ENV_BACKUP)"
  recreate_app "$APP" "$APP_IMAGE" pre-pg16
  STAGE=app_started
  app_health_check 90 || auto_rollback
  verify_runtime_env "$APP" || auto_rollback

  trap _on_err ERR
  STAGE="done"
  state_set db.migrated "$TS"

  step "7. Backups"
  set_backup_target "$DB_CONTAINER_NEW" "$ADMIN_USER" "$APP_DB"
  if [[ -x /usr/local/sbin/jerboa-backup ]]; then
    /usr/local/sbin/jerboa-backup --db-only || warn "first PG16 dump failed; run: jerboa-backup --db-only"
  fi

  set_rollback "./migrate_db.sh --rollback     # dumps PG16 first, then back to $OLD_DB"
  step "Done: the chat runs on $PG_IMAGE ($PG_DIGEST)"
  cat <<EOF
  database   : $DB_CONTAINER_NEW, data in $PGDATA_NEW, app role '$APP_ROLE', db '$APP_DB'
  old        : $OLD_DB is stopped (restart policy no) and kept for rollback/forensics,
               its data dir $OLD_DATA is untouched. Remove both after a quiet week
               (RUNBOOK.md, "After phase 4").
  secrets    : $ENV_FILE (app), $ADMIN_ENV (PG superuser '$ADMIN_USER', TCP only)
  If you ever restart $DB_CONTAINER_NEW, restart $APP afterwards: the backend
  keeps one connection and does not reconnect by itself.
EOF
  print_rollback
}

# -------------------------------------------------------------- rollback ----

manual_rollback() {
  start_log
  require_root
  local old app image env_backup ts dump
  old=$(state_get db.old_container)
  env_backup=$(state_get db.env_backup)
  [[ -n $(state_get db.migrated) ]] || die "no migration recorded in $STATE_DIR/db.migrated"
  if [[ -z $old ]] || ! container_exists "$old"; then
    die "old database container '$old' is gone; cannot roll back"
  fi
  [[ -f $env_backup ]] || die "env backup '$env_backup' is missing"
  app=$(find_running_app_containers | head -n1)
  [[ -n $app ]] || app=$(state_get app.current)
  [[ -n $app ]] || die "cannot tell which backend container to recreate"
  image=$(container_image "$app")
  ts=$(ts_utc)

  step "Rollback to $old"
  warn "Everything written to the chat since the migration is NOT in $old."
  warn "A dump of PG16 is taken first, so nothing is lost for good."
  confirm "Stop the backend, stop $DB_CONTAINER_NEW, go back to $old?" rollback || die "aborted; nothing changed"

  dump="$BACKUP_DIR/db/pg16-before-rollback-$ts.dump"
  if container_running "$DB_CONTAINER_NEW"; then
    docker exec "$DB_CONTAINER_NEW" pg_dump -U "$ADMIN_USER" -d "$APP_DB" -Fc > "$dump"
    chmod 600 "$dump"
    ok "PG16 dumped to $dump"
  fi
  docker stop -t 20 "$app" >/dev/null 2>&1 || true
  docker stop -t 30 "$DB_CONTAINER_NEW" >/dev/null 2>&1 || true
  docker update --restart=no "$DB_CONTAINER_NEW" >/dev/null 2>&1 || true
  ok "stopped $app and $DB_CONTAINER_NEW (both kept)"
  cp -p "$ENV_FILE" "$STATE_DIR/jerboa.env.pg16-$ts"
  cp -p "$env_backup" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "restored $ENV_FILE from $env_backup (PG16 version kept as $STATE_DIR/jerboa.env.pg16-$ts)"
  docker start "$old" >/dev/null
  wait_pg_ready "$old" postgres 90 || die "$old did not come back; look at docker logs $old"
  recreate_app "$app" "$image" pg16 || die "could not recreate $app"
  if app_health_check 90; then
    ok "backend healthy on $old"
  else
    die "backend not healthy; check docker logs $app"
  fi
  set_backup_target "$old" postgres postgres
  mv "$STATE_DIR/db.migrated" "$STATE_DIR/db.migrated.rolledback-$ts"
  log "PG16 is stopped, not removed: $DB_CONTAINER_NEW, data in $PGDATA_NEW."
  log "To retry the migration later: docker rm $DB_CONTAINER_NEW; mv $PGDATA_NEW $PGDATA_NEW.old-$ts"
}

# ---------------------------------------------------------------- main ----

# The tests source this file with JERBOA_SOURCE_ONLY=1 to reach the helpers.
if [[ ${JERBOA_SOURCE_ONLY:-0} == 1 ]]; then return 0; fi

case $MODE in
  status) show_status ;;
  rehearse) rehearse ;;
  rollback) manual_rollback ;;
  migrate) migrate ;;
esac
