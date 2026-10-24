#!/usr/bin/env bash
# Local tests for deploy/: everything that can be checked without the server,
# without docker and without root. Run from anywhere:
#
#     deploy/tests/run_local_tests.sh
#
# Groups (a group is skipped if its tool is missing):
#   env        secrets file: mode, docker --env-file round trip, nothing printed,
#              python-dotenv 0.13.0 (the image's) quote and override behaviour  [uv]
#   docker     the generated code-only Dockerfile; hadolint                     [uv]
#   backup     retention by name, newest-3 rule, rsync hard-link snapshots
#   frontend   tarball safety checks, site validation, directory swap
#   nginx      the hardened config renders, is idempotent and passes nginx -t  [nginx]
#   daemon     daemon.json merge
#   postgres   migrate_db.sh SQL against a real Postgres 16.2: initdb flags and
#              pg_hba, audit, role + db, non-superuser restore, counts, what the
#              app role can and cannot do, libpq env vars via psycopg2        [uv]
#   git        resolve_ref for branch, short sha and tag
#
# Exit status: 0 when nothing failed.
#
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2119,SC2120,SC2329
#   SC1091  the scripts under test are sourced by path at run time
#   SC2016  fixtures contain a literal '$' on purpose
#   SC2030/SC2031  every test group runs in its own subshell on purpose
#   SC2034  variables set here are read by the sourced scripts
#   SC2119/SC2120/SC2329  helpers are called through t / t_fails

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DEPLOY=$(dirname "$HERE")
REPO=$(dirname "$DEPLOY")
T=$(mktemp -d "${TMPDIR:-/tmp}/jerboa-tests.XXXXXX")
RESULTS=$T/results
: > "$RESULTS"
PGPORT_TEST=55433

cleanup() {
  if [[ -f $T/pg.bin ]]; then
    "$(cat "$T/pg.bin")/pg_ctl" -D "$T/pg/data" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$T"
}
trap cleanup EXIT

# ------------------------------------------------------------ harness ----

t() { # <description> <command...>: passes when the command succeeds
  local name=$1; shift
  if ( "$@" ) >/dev/null 2>&1; then
    echo "PASS $name" >> "$RESULTS"; printf '  ok    %s\n' "$name"
  else
    echo "FAIL $name" >> "$RESULTS"; printf '  FAIL  %s\n' "$name"
  fi
}
t_fails() { # <description> <command...>: passes when the command fails
  local name=$1; shift
  if ( "$@" ) >/dev/null 2>&1; then
    echo "FAIL $name" >> "$RESULTS"; printf '  FAIL  %s (it should have failed)\n' "$name"
  else
    echo "PASS $name" >> "$RESULTS"; printf '  ok    %s\n' "$name"
  fi
}
skip()  { echo "SKIP $1" >> "$RESULTS"; printf '  skip  %s\n' "$1"; }
group() { printf '\n== %s\n' "$1"; }
not()   { ! "$@"; }
have()  { command -v "$1" >/dev/null 2>&1; }

file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
inode()     { stat -f %i "$1" 2>/dev/null || stat -c %i "$1"; }
ts_ago() { # <days> -> UTC timestamp <days> days and one hour ago
  date -u -v-"$1"d -v-1H +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -d "-$1 days -1 hour" +%Y%m%dT%H%M%SZ
}
envfile_get() { python3 "$HERE/docker_envfile.py" "$1" "$2"; }

run_group() { # <function>
  ( "$1" ) || { echo "FAIL group $1 aborted (exit $?)" >> "$RESULTS"; printf '  FAIL  group %s aborted\n' "$1"; }
}

# ---------------------------------------------------------------- env ----

group_env() {
  group "env: secrets file"
  export STATE_DIR="$T/env/state" ENV_FILE="$T/env/jerboa.env"
  mkdir -p "$T/env"
  # shellcheck source=../deploy_app.sh
  JERBOA_SOURCE_ONLY=1 source "$DEPLOY/deploy_app.sh"

  local nasty out val
  nasty='p@ss w$rd #1 "q" '"'s'"' \n =x `id` $(id)'
  out=$(write_env_file "$ENV_FILE" "$nasty" "$(gen_secret)" 2>&1)
  t "write_env_file prints nothing" test -z "$out"
  t "env file has mode 0600" test "$(file_mode "$ENV_FILE")" = 600
  t "docker --env-file reads db_pass back byte for byte" test "$(envfile_get "$ENV_FILE" db_pass)" = "$nasty"
  t "flask_secret is 64 hex characters" grep -qE '^flask_secret=[0-9a-f]{64}$' "$ENV_FILE"
  t "two generated secrets differ" test "$(gen_secret)" != "$(gen_secret)"
  t "env_get returns the value including '=' and quotes" test "$(env_get db_pass "$ENV_FILE")" = "$nasty"

  out=$(env_set db_user jerboa "$ENV_FILE"; env_set flask_secret replaced "$ENV_FILE" 2>&1)
  t "env_set prints nothing" test -z "$out"
  t "env_set appends a new key" test "$(envfile_get "$ENV_FILE" db_user)" = jerboa
  t "env_set replaces a key in place (one line)" test "$(grep -c '^flask_secret=' "$ENV_FILE")" = 1
  t "env_set leaves other keys alone" test "$(envfile_get "$ENV_FILE" db_pass)" = "$nasty"
  t "env_set keeps mode 0600" test "$(file_mode "$ENV_FILE")" = 600
  t_fails "env_set refuses a value with a newline" env_set k $'a\nb' "$ENV_FILE"
  out=$(backup_secret_file "$ENV_FILE" test)
  t "backup_secret_file writes a 0600 copy" test "$(file_mode "$out")" = 600

  if have uv; then
    # The image's .env has double-quoted values; python-dotenv strips the quotes.
    printf 'VUE_APP_VERSION="Fri May  1 17:00:00 CEST 2020"\ndb_pass="s3cr$t #with spaces"\nflask_secret="baked-in"\n' > "$T/env/dot.env"
    val=$(uv run -q --no-project --with python-dotenv==0.13.0 python -c '
import os, sys
from dotenv import load_dotenv
os.environ["flask_secret"] = "from-env-file"          # what --env-file would have set
load_dotenv(sys.argv[1], override=True)               # exactly what pipenv 2018.11.26 does
sys.stdout.write(os.environ["db_pass"] + "\n" + os.environ["flask_secret"])' "$T/env/dot.env")
    t "python-dotenv 0.13.0 strips the quotes (the value the app sees)" test "${val%%$'\n'*}" = 's3cr$t #with spaces'
    t "pipenv-style load (override=True) beats --env-file: why the new image deletes .env" test "${val##*$'\n'}" = baked-in
    write_env_file "$T/env/from-dotenv.env" "${val%%$'\n'*}" x
    t "that value survives our env file unchanged" test "$(envfile_get "$T/env/from-dotenv.env" db_pass)" = 's3cr$t #with spaces'
  else
    skip "python-dotenv checks (no uv)"
  fi
}

# ------------------------------------------------------------- docker ----

group_docker() {
  group "docker: generated Dockerfile"
  # shellcheck source=../deploy_app.sh
  JERBOA_SOURCE_ONLY=1 source "$DEPLOY/deploy_app.sh"
  local sha=0123456789abcdef0123456789abcdef01234567 d0="$T/docker/Dockerfile.code" d1="$T/docker/Dockerfile.runpy"
  mkdir -p "$T/docker"
  render_dockerfile "$sha" sha256:79cf47d3bf67 0 > "$d0"
  render_dockerfile "$sha" sha256:79cf47d3bf67 1 > "$d1"
  t "FROM chat:latest (the 2020 image, nothing else)" test "$(grep '^FROM' "$d0")" = "FROM chat:latest"
  t "deletes the baked-in /chat_app/.env" grep -q '^RUN rm -rf /chat_app/app /chat_app/.env$' "$d0"
  t "sets PIPENV_DONT_LOAD_ENV=1" grep -qx 'ENV PIPENV_DONT_LOAD_ENV=1' "$d0"
  t "copies app/" grep -qx 'COPY app/ /chat_app/app/' "$d0"
  t "only one RUN, and it installs nothing" test "$(grep -c '^RUN' "$d0")" = 1
  t "no run.py copy when run.py is unchanged" not grep -q 'run.py' "$d0"
  t "copies run.py when it changed" grep -qx 'COPY run.py /chat_app/run.py' "$d1"
  t "labels the git revision" grep -q "org.opencontainers.image.revision=\"$sha\"" "$d0"
  if have uvx; then
    t "hadolint passes (DL3007 ignored: FROM chat:latest is deliberate)" \
      uvx -q --from hadolint-bin hadolint --ignore DL3007 "$d1"
  else
    skip "hadolint (no uvx)"
  fi
}

# ------------------------------------------------------------- backup ----

group_backup() {
  group "backup: retention and snapshots"
  local B="$T/backup" d n
  mkdir -p "$B/up/chat_images" "$B/up/chat_emoijs"
  cat > "$B/conf" <<EOF
DB_CONTAINER=x
DB_USER=postgres
DB_NAME=postgres
BACKUP_DIR=$B/backups
RETENTION_DAYS=14
UPLOADS_DIRS="$B/up/chat_images $B/up/chat_emoijs"
UPLOADS_MODE=snapshot
EOF
  export JERBOA_BACKUP_CONF="$B/conf"
  # shellcheck source=../files/jerboa-backup.sh
  JERBOA_BACKUP_SOURCE_ONLY=1 source "$DEPLOY/files/jerboa-backup.sh"
  load_conf
  mkdir -p "$DB_DIR" "$UP_DIR"

  local -a names=()
  for d in $(seq 0 29); do names[d]="jerboa-db-$(ts_ago "$d").dump"; done
  for d in $(seq 0 29); do : > "$DB_DIR/${names[d]}"; : > "$DB_DIR/${names[d]}.sha256"; done
  : > "$DB_DIR/premigrate-pg11-20200101T000000Z.dump"
  prune_by_name "$DB_DIR" jerboa-db- .dump >/dev/null
  n=$(find "$DB_DIR" -name 'jerboa-db-*.dump' | wc -l | tr -d ' ')
  t "keeps exactly the 14 dumps younger than 14 days (of 30)" test "$n" = 14
  n=$(find "$DB_DIR" -name 'jerboa-db-*.dump.sha256' | wc -l | tr -d ' ')
  t "a pruned dump takes its .sha256 with it" test "$n" = 14
  t "the newest dump is kept" test -e "$DB_DIR/${names[0]}"
  t "the oldest kept dump is 13 days old" test -e "$DB_DIR/${names[13]}"
  t "the 14-day-old dump is gone" not test -e "$DB_DIR/${names[14]}"
  t "pre-migration dumps are never pruned" test -e "$DB_DIR/premigrate-pg11-20200101T000000Z.dump"

  mkdir -p "$B/stale"
  for d in 20 21 22 23 24; do : > "$B/stale/${names[d]}"; done
  prune_by_name "$B/stale" jerboa-db- .dump >/dev/null
  t "timer dead for weeks: the newest 3 survive anyway" test "$(find "$B/stale" -type f | wc -l | tr -d ' ')" = 3
  t "... and they are the 3 newest" test -e "$B/stale/${names[20]}" -a -e "$B/stale/${names[22]}" -a ! -e "$B/stale/${names[23]}"

  if have rsync; then
    echo one > "$B/up/chat_images/a.png"
    echo emo > "$B/up/chat_emoijs/e.png"
    TS=20260101T000000Z snapshot_uploads >/dev/null
    echo two > "$B/up/chat_images/b.png"
    TS=20260102T000000Z snapshot_uploads >/dev/null
    rm "$B/up/chat_images/a.png"
    TS=20260103T000000Z snapshot_uploads >/dev/null
    t "snapshot holds both upload dirs" test -f "$UP_DIR/20260101T000000Z/chat_images/a.png" -a -f "$UP_DIR/20260101T000000Z/chat_emoijs/e.png"
    t "unchanged files are hard links to the previous snapshot" \
      test "$(inode "$UP_DIR/20260101T000000Z/chat_images/a.png")" = "$(inode "$UP_DIR/20260102T000000Z/chat_images/a.png")"
    t "a new upload appears in the next snapshot" test -f "$UP_DIR/20260102T000000Z/chat_images/b.png"
    t "a deleted upload stays in older snapshots" test -f "$UP_DIR/20260102T000000Z/chat_images/a.png"
    t "... and is absent from newer ones" not test -e "$UP_DIR/20260103T000000Z/chat_images/a.png"
    t "snapshots never share inodes with the live dir" \
      test "$(inode "$B/up/chat_images/b.png")" != "$(inode "$UP_DIR/20260103T000000Z/chat_images/b.png")"
    t "latest -> newest snapshot" test "$(readlink "$UP_DIR/latest")" = 20260103T000000Z
    RETENTION_DAYS=14 prune_by_name "$UP_DIR" "" "" >/dev/null
    t "snapshot pruning keeps the newest 3 even when old" test -d "$UP_DIR/20260101T000000Z"
    t "snapshot pruning leaves the latest symlink" test -L "$UP_DIR/latest"
  else
    skip "rsync snapshots (no rsync)"
  fi

  (
    # shellcheck source=../backup.sh
    JERBOA_SOURCE_ONLY=1 source "$DEPLOY/backup.sh"
    render_conf naughty_rubin postgres postgres
  ) > "$B/rendered.conf"
  t "rendered /etc/jerboa-backup.conf has no @placeholders@ left" not grep -q '@' "$B/rendered.conf"
  t "rendered config names the DB container" grep -qx 'DB_CONTAINER=naughty_rubin' "$B/rendered.conf"
  t "rendered config is valid shell" bash -n "$B/rendered.conf"

  cp "$B/rendered.conf" "$B/repoint.conf"
  chmod 600 "$B/repoint.conf"
  (
    export BACKUP_CONF="$B/repoint.conf" STATE_DIR="$B/state"
    # shellcheck source=../lib.sh
    source "$DEPLOY/lib.sh"
    set_backup_target jerboa-db pgadmin jerboa
  ) >/dev/null 2>&1
  t "set_backup_target repoints the three DB_ lines (migrate_db.sh, step 7)" \
    test "$(grep -E '^DB_(CONTAINER|USER|NAME)=' "$B/repoint.conf" | tr '\n' ' ')" = "DB_CONTAINER=jerboa-db DB_USER=pgadmin DB_NAME=jerboa "
  t "set_backup_target keeps everything else" test "$(grep -vE '^DB_' "$B/repoint.conf")" = "$(grep -vE '^DB_' "$B/rendered.conf")"
  t "set_backup_target keeps mode 0600" test "$(file_mode "$B/repoint.conf")" = 600
}

# ----------------------------------------------------------- frontend ----

LIVE_INDEX='<!DOCTYPE html><html><head><meta charset=utf-8><meta http-equiv=X-UA-Compatible content="IE=edge"><meta name=viewport content="width=device-width,initial-scale=1,maximum-scale=1"><link rel="shortcut icon" href=/favicon.ico><link rel=stylesheet href=https://cdnjs.cloudflare.com/ajax/libs/KaTeX/0.5.1/katex.min.css><link href=/icons/all.min.css rel=stylesheet><title>Jerboa</title><link href=/css/app.22ebc918.css rel=preload as=style><link href=/css/chunk-vendors.6af9d10e.css rel=preload as=style><link href=/js/app.12818ca3.js rel=preload as=script><link href=/js/chunk-vendors.d3ed3bd7.js rel=preload as=script><link href=/css/chunk-vendors.6af9d10e.css rel=stylesheet><link href=/css/app.22ebc918.css rel=stylesheet></head><body><div id=app></div><script src=/js/chunk-vendors.d3ed3bd7.js></script><script src=/js/app.12818ca3.js></script></body></html>'

make_dist() { # <dir>: a build shaped like the live one
  mkdir -p "$1/css" "$1/js" "$1/icons"
  printf '%s' "$LIVE_INDEX" > "$1/index.html"
  echo 'body{}' > "$1/css/app.22ebc918.css"
  echo 'a{}' > "$1/css/chunk-vendors.6af9d10e.css"
  echo 'var base="https://chat.ipieter.be/api/";' > "$1/js/app.12818ca3.js"
  echo 'var v=1;' > "$1/js/chunk-vendors.d3ed3bd7.js"
  echo 'i{}' > "$1/icons/all.min.css"
  echo ico > "$1/favicon.ico"
}

group_frontend() {
  group "frontend: tarball checks, validation, swap"
  local F="$T/fe"
  mkdir -p "$F"
  export WEBROOT="$F/www/html" PUBLIC_HOST=chat.ipieter.be STATE_DIR="$F/state"
  # shellcheck source=../deploy_frontend.sh
  JERBOA_SOURCE_ONLY=1 source "$DEPLOY/deploy_frontend.sh"

  make_dist "$F/dist"
  tar -czf "$F/flat.tgz" -C "$F/dist" .
  tar -czf "$F/prefixed.tgz" -C "$F" dist
  python3 - "$F" <<'PY'
import io, sys, tarfile
d = sys.argv[1]
def make(name, member):
    with tarfile.open(f"{d}/{name}", "w:gz") as tf:
        data = b"x"
        ok = tarfile.TarInfo("index.html"); ok.size = 1
        tf.addfile(ok, io.BytesIO(data))
        if member.type == tarfile.REGTYPE:
            member.size = 1
            tf.addfile(member, io.BytesIO(data))
        else:
            tf.addfile(member)
make("abs.tgz", tarfile.TarInfo("/etc/cron.d/evil"))
make("dotdot.tgz", tarfile.TarInfo("../../root/.ssh/authorized_keys"))
sl = tarfile.TarInfo("js"); sl.type = tarfile.SYMTYPE; sl.linkname = "/etc"
make("symlink.tgz", sl)
hl = tarfile.TarInfo("passwd"); hl.type = tarfile.LNKTYPE; hl.linkname = "/etc/passwd"
make("hardlink.tgz", hl)
PY
  echo "not a tarball" > "$F/plain.tgz"

  t "clean tarball (files at the top) passes" check_tar_listing "$F/flat.tgz"
  t "clean tarball (under dist/) passes" check_tar_listing "$F/prefixed.tgz"
  t_fails "absolute path is refused" check_tar_listing "$F/abs.tgz"
  t_fails "'..' path is refused" check_tar_listing "$F/dotdot.tgz"
  t_fails "symlink is refused" check_tar_listing "$F/symlink.tgz"
  t_fails "hard link is refused" check_tar_listing "$F/hardlink.tgz"
  t_fails "a file that is not a .tar.gz is refused" check_tar_listing "$F/plain.tgz"

  mkdir -p "$F/u1" "$F/u2" "$F/u3/a" "$F/u3/b"
  tar -xzf "$F/flat.tgz" -C "$F/u1"
  tar -xzf "$F/prefixed.tgz" -C "$F/u2"
  : > "$F/u3/a/index.html"; : > "$F/u3/b/index.html"
  t "site root: index.html at the top" test "$(find_site_root "$F/u1")" = "$F/u1"
  t "site root: one level down (dist/)" test "$(find_site_root "$F/u2")" = "$F/u2/dist"
  t_fails "site root: two candidates is ambiguous" find_site_root "$F/u3"

  t "finds the 4 js/css files the live index.html loads" test "$(referenced_assets "$F/dist/index.html" | wc -l | tr -d ' ')" = 4
  t "accepts a complete production build" validate_site "$F/dist"
  cp -R "$F/dist" "$F/missing"; rm "$F/missing/js/app.12818ca3.js"
  t_fails "refuses a build with a missing asset" validate_site "$F/missing"
  cp -R "$F/dist" "$F/devbuild"; echo 'var base="http://localhost:9000/";' > "$F/devbuild/js/app.12818ca3.js"
  t_fails "refuses a development build (localhost:9000)" validate_site "$F/devbuild"

  mkdir -p "$F/sw/live" "$F/sw/new"
  echo old > "$F/sw/live/f"; echo new > "$F/sw/new/f"
  swap_dirs "$F/sw/live" "$F/sw/new" >/dev/null 2>&1
  t "swap: the live path serves the new tree" grep -qx new "$F/sw/live/f"
  t "swap: the staged path now holds the old tree (becomes the backup)" grep -qx old "$F/sw/new/f"
  if [[ $(uname -s) != Linux ]]; then
    skip "renameat2 RENAME_EXCHANGE itself (Linux only; the fallback was tested above)"
  fi
}

# -------------------------------------------------------------- nginx ----

group_nginx() {
  group "nginx: render, idempotence, nginx -t"
  local N="$T/nginx" E le stage
  E="$N/etc-nginx"; le="$N/le"
  export NGINX_BIN
  NGINX_BIN=$(command -v nginx || echo /opt/homebrew/bin/nginx)
  mkdir -p "$E/conf.d" "$E/snippets" "$E/modules-enabled" "$E/sites-enabled" "$le/live/chat.ipieter.be" "$N/logs" "$N/work"
  openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=chat.ipieter.be -days 2 \
    -keyout "$le/live/chat.ipieter.be/privkey.pem" -out "$le/live/chat.ipieter.be/fullchain.pem" >/dev/null 2>&1
  openssl dhparam -dsaparam -out "$le/ssl-dhparams.pem" 2048 >/dev/null 2>&1
  cp "$(dirname "$(dirname "$NGINX_BIN")")/etc/nginx/mime.types" "$E/mime.types" 2>/dev/null ||
    cp /opt/homebrew/etc/nginx/mime.types "$E/mime.types"

  # The live files as `nginx -T` showed them, with paths that only exist on
  # the server pointed into the temp dir (logs, letsencrypt).
  cat > "$E/nginx.conf" <<EOF
user www-data;
worker_processes auto;
pid $N/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;
events {
	worker_connections 768;
}
http {
	root /root/chat/dist;
	sendfile on;
	tcp_nopush on;
	tcp_nodelay on;
	keepalive_timeout 65;
	types_hash_max_size 2048;
	# server_tokens off;
	include /etc/nginx/mime.types;
	default_type application/octet-stream;
	ssl_protocols TLSv1 TLSv1.1 TLSv1.2; # Dropping SSLv3, ref: POODLE
	ssl_prefer_server_ciphers on;
	access_log $N/logs/access.log;
	error_log $N/logs/error.log;
	gzip on;
	# gzip_vary on;
	include /etc/nginx/conf.d/*.conf;
	include /etc/nginx/sites-enabled/*;
}
EOF
  cat > "$le/options-ssl-nginx.conf" <<'EOF'
ssl_session_cache shared:le_nginx_SSL:1m;
ssl_session_timeout 1440m;
ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
ssl_prefer_server_ciphers on;
ssl_ciphers "ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-DES-CBC3-SHA:DES-CBC3-SHA:!DSS";
EOF
  cat > "$E/conf.d/www.chat.ipieter.be.conf" <<EOF
server {
    root /var/www/html;
    server_name chat.ipieter.be www.chat.ipieter.be;
    access_log $N/logs/nginx_access.log;
    error_log $N/logs/nginx_error.log;
    client_max_body_size 256M;

    listen [::]:443 ssl ipv6only=on; # managed by Certbot
    listen 443 ssl; # managed by Certbot
    ssl_certificate $le/live/chat.ipieter.be/fullchain.pem; # managed by Certbot
    ssl_certificate_key $le/live/chat.ipieter.be/privkey.pem; # managed by Certbot
    include $le/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam $le/ssl-dhparams.pem; # managed by Certbot

    location / {
        try_files \$uri \$uri/ /index.html?uri=\$uri;
    }
    location /emoji/ {
        proxy_pass http://127.0.0.1:9000/emoji/;
    }
    location /api/ {
        proxy_pass http://127.0.0.1:9000/;
    }
    location /socket.io/ {
 	proxy_redirect off;
        proxy_buffering off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
	proxy_http_version 1.1;
	proxy_set_header Upgrade \$http_upgrade;
	proxy_set_header Connection "Upgrade";
        proxy_pass http://127.0.0.1:9000;
    }
}
server {
    if (\$host = chat.ipieter.be) {
        return 301 https://\$host\$request_uri;
    } # managed by Certbot
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name chat.ipieter.be www.chat.ipieter.be;
    return 404; # managed by Certbot
}
EOF
  export WORK="$N/work"
  # shellcheck source=../harden_nginx.sh
  JERBOA_SOURCE_ONLY=1 source "$DEPLOY/harden_nginx.sh"
  local site="$E/conf.d/www.chat.ipieter.be.conf" cert key dh
  cert=$(conf_value ssl_certificate "$site")
  key=$(conf_value ssl_certificate_key "$site")
  dh=$(conf_value ssl_dhparam "$site")
  t "conf_value: ssl_certificate (not confused with _key)" test "$cert" = "$le/live/chat.ipieter.be/fullchain.pem"
  t "conf_value: ssl_certificate_key" test "$key" = "$le/live/chat.ipieter.be/privkey.pem"
  t "conf_value: ssl_dhparam" test "$dh" = "$le/ssl-dhparams.pem"
  t "the live config (fixture) passes nginx -t" test_stage "$E"

  stage="$N/stage"
  cp -a "$E" "$stage"
  render_stage "$stage" "$cert" "$key" "$dh" "TLSv1.2 TLSv1.3"
  cp -a "$stage" "$N/stage2"
  render_stage "$N/stage2" "$cert" "$key" "$dh" "TLSv1.2 TLSv1.3"
  t "rendering twice changes nothing (idempotent)" diff -r "$stage" "$N/stage2"
  # the template has the server's log paths; point them into the temp dir to test
  sed "s|/root/chat/logs|$N/logs|g" "$stage/conf.d/www.chat.ipieter.be.conf" > "$N/site.tmp" &&
    mv "$N/site.tmp" "$stage/conf.d/www.chat.ipieter.be.conf"
  local new="$stage/conf.d/www.chat.ipieter.be.conf" sn="$stage/snippets"
  t "the hardened config passes nginx -t" test_stage "$stage"
  t "nginx.conf: http-level ssl_protocols is TLSv1.2 TLSv1.3" grep -qE '^[[:space:]]*ssl_protocols TLSv1.2 TLSv1.3;' "$stage/nginx.conf"
  t "server block no longer includes options-ssl-nginx.conf" not grep -qE '^[[:space:]]*include[^#]*options-ssl-nginx' "$new"
  t "certbot's cert lines are kept as they were" grep -qF "ssl_certificate $cert; # managed by Certbot" "$new"
  t "TLS snippet: no TLSv1 or TLSv1.1" not grep -qE 'TLSv1(\.1)?[ ;]' "$sn/jerboa-tls.conf"
  aead_only() { ! grep -E '^ssl_ciphers' "$1" | grep -qiE 'des|cbc|-sha[:;]|-sha$'; }
  t "TLS snippet: ciphers are AEAD only (no 3DES, no CBC/SHA1 suites)" aead_only "$sn/jerboa-tls.conf"
  t "client_max_body_size 50m" grep -q 'client_max_body_size 50m;' "$new"
  t "all 3 proxied locations include jerboa-proxy.conf" test "$(grep -c 'include /etc/nginx/snippets/jerboa-proxy.conf' "$new")" = 3
  t "X-Forwarded-For goes to the backend" grep -q 'proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;' "$sn/jerboa-proxy.conf"
  t "HSTS starts at max-age=300" grep -q 'Strict-Transport-Security "max-age=300" always' "$sn/jerboa-security-headers.conf"
  t "CSP is report-only (not enforced yet)" not grep -qE '^add_header Content-Security-Policy ' "$sn/jerboa-security-headers.conf"
  t "X-Frame-Options SAMEORIGIN (the PDF preview iframe)" grep -q 'X-Frame-Options "SAMEORIGIN"' "$sn/jerboa-security-headers.conf"
  t "server_tokens off and gzip_types at http level" grep -q '^server_tokens off;' "$stage/conf.d/00-jerboa-http.conf"
  local loc nlost=0
  for loc in / /emoji/ /api/ /socket.io/; do grep -qF "location $loc " "$new" || nlost=1; done
  t "all four live locations are still there" test "$nlost" = 0

  cp -a "$stage" "$N/broken"
  echo 'bogus_directive on;' >> "$N/broken/snippets/jerboa-tls.conf"
  t_fails "a broken staged config fails test_stage" test_stage "$N/broken"
}

# ------------------------------------------------------------- daemon ----

group_daemon() {
  group "daemon.json merge"
  local D="$T/daemon" out
  mkdir -p "$D"
  # shellcheck source=../ops_hygiene.sh
  JERBOA_SOURCE_ONLY=1 source "$DEPLOY/ops_hygiene.sh"
  out=$(merge_daemon_json "")
  t "new file: json-file, max-size 10m, max-file 3" python3 -c '
import json, sys
assert json.loads(sys.argv[1]) == {"log-driver": "json-file", "log-opts": {"max-size": "10m", "max-file": "3"}}' "$out"
  echo '{"live-restore": true, "log-opts": {"labels": "jerboa"}}' > "$D/existing.json"
  out=$(merge_daemon_json "$D/existing.json")
  t "existing settings are kept" python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["live-restore"] is True and d["log-opts"]["labels"] == "jerboa" and d["log-opts"]["max-file"] == "3"' "$out"
  echo '{broken' > "$D/broken.json"
  t_fails "invalid JSON is refused (would stop dockerd from starting)" merge_daemon_json "$D/broken.json"
  echo '[]' > "$D/array.json"
  t_fails "a JSON array is refused" merge_daemon_json "$D/array.json"
}

# ----------------------------------------------------------- postgres ----

# Stand-in for `docker exec [-i] [-e NAME] <container> <cmd...>`: runs <cmd>
# here against the test cluster (TCP on 127.0.0.1; no unix socket because
# macOS limits socket paths to 104 bytes).
docker() {
  [[ $1 == exec ]] || { echo "docker shim: unsupported: $*" >&2; return 99; }
  shift
  while [[ $1 == -* ]]; do
    case $1 in
      -i) shift ;;
      -e) shift 2 ;;     # -e NAME: already in our environment
      *) echo "docker shim: unknown flag $1" >&2; return 99 ;;
    esac
  done
  shift   # container name
  PGDATA="${SHIM_PGDATA:-$T/pg/data}" PGHOST=127.0.0.1 PGPASSWORD="${SHIM_PGPASSWORD:-$ADMINPW}" \
    PATH="$PGBIN:$PATH" "$@"
}

migrations_sql() { # every yoyo step's apply SQL, in file order
  python3 - "$REPO/migrations" <<'PY'
import ast, os, sys
d = sys.argv[1]
for name in sorted(f for f in os.listdir(d) if f.endswith(".py")):
    tree = ast.parse(open(os.path.join(d, name)).read())
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and getattr(node.func, "id", "") == "step":
            arg = node.args[0]
            sql = arg.value if isinstance(arg, ast.Constant) else arg.s
            print(sql.strip().rstrip(";") + ";")
PY
}

group_postgres() {
  group "postgres: migrate_db.sh SQL against Postgres 16"
  if ! have uv; then skip "postgres group (no uv)"; return 0; fi
  PGBIN=$(uv run -q --no-project --python 3.12 --with pgserver python -c \
    'import os, pgserver; print(os.path.join(os.path.dirname(pgserver.__file__), "pginstall", "bin"))' 2>/dev/null) ||
    { skip "postgres group (could not get pgserver)"; return 0; }
  export PGBIN ADMINPW=admin-test-pw
  local P="$T/pg" initdb_args unknown jpw
  mkdir -p "$P"
  export STATE_DIR="$P/state" ENV_FILE="$P/jerboa.env"
  # shellcheck source=../migrate_db.sh
  JERBOA_SOURCE_ONLY=1 source "$DEPLOY/migrate_db.sh"
  set +e   # keep going after a failed check; every check reports itself

  write_admin_env "$P/admin.env" "$ADMINPW"
  initdb_args=$(envfile_get "$P/admin.env" POSTGRES_INITDB_ARGS)
  t "admin env: POSTGRES_USER=pgadmin" test "$(envfile_get "$P/admin.env" POSTGRES_USER)" = pgadmin
  t "admin env: initdb args survive --env-file with their space" test "$initdb_args" = "--auth-host=scram-sha-256 --auth-local=trust"
  t "admin env: mode 0600" test "$(file_mode "$P/admin.env")" = 600

  # What the official image's entrypoint does with those variables:
  #   initdb --username="$POSTGRES_USER" --pwfile=<(...) $POSTGRES_INITDB_ARGS
  #   then appends "host all all all scram-sha-256" to pg_hba.conf
  # shellcheck disable=SC2086
  "$PGBIN/initdb" -D "$P/data" --username=pgadmin --pwfile=<(printf '%s\n' "$ADMINPW") $initdb_args >/dev/null 2>&1
  printf '\nhost all all all scram-sha-256\n' >> "$P/data/pg_hba.conf"
  echo "$PGBIN" > "$T/pg.bin"
  if ! "$PGBIN/pg_ctl" -D "$P/data" -l "$P/server.log" -w \
       -o "-c listen_addresses=localhost -c port=$PGPORT_TEST -c unix_socket_directories='' -c password_encryption=scram-sha-256" \
       start >/dev/null; then
    tail -n 20 "$P/server.log"
    echo "FAIL postgres did not start" >> "$RESULTS"
    return 0
  fi

  NEW_C=test NEW_PORT=$PGPORT_TEST
  t "the initdb args give scram-sha-256 on every TCP line, no trust" verify_pg16_hardening
  mkdir -p "$P/badhba"
  printf 'local all all trust\nhost all all 127.0.0.1/32 trust\nhost all all all scram-sha-256\n' > "$P/badhba/pg_hba.conf"
  bad_hba() { SHIM_PGDATA="$P/badhba" verify_pg16_hardening; }
  t_fails "the image's default (127.0.0.1 trust) would be caught" bad_hba

  psql_admin() { PGPASSWORD=$ADMINPW "$PGBIN/psql" -X -q -h 127.0.0.1 -p "$PGPORT_TEST" -U pgadmin -v ON_ERROR_STOP=1 "$@"; }
  # The "old" database: the real migrations, yoyo's tables, some rows.
  psql_admin -d postgres -c 'create database srcdb' >/dev/null
  migrations_sql | psql_admin -d srcdb >/dev/null
  psql_admin -d srcdb >/dev/null <<'SQL'
create table _yoyo_migration (migration_hash text, migration_id text, applied_at_utc timestamp);
create table _yoyo_log (id text, migration_hash text, operation text);
create table _yoyo_version (version int, installed_at_utc timestamp);
create table yoyo_lock (locked int, ctime timestamp, pid int);
insert into users (username, password, display_name, state)
  values ('a@x', 'pbkdf2:x', 'A', 'USER'), ('b@x', 'pbkdf2:y', 'B', 'ADMIN'), ('c@x', 'pbkdf2:z', 'C', 'REQUESTED');
insert into channels_users (channel_id, user_id, joined) select 1, id, 0 from users;
insert into messages (sender, channel, message, sent_time) select 1, '1', 'm' || g, g from generate_series(1, 250) g;
insert into files (file, user_id, type, size, full_name) values ('abc', 1, 'image/png', 10, 'a.png');
insert into emojis (name, added, user_id, file) values ('party', 0, 1, 'p.png');
insert into active_logins (last_seen, active, device, client, expires, user_id) values (0, 1, 'mac', 'safari', 0, 1);
SQL
  t "the real migrations replay on PG16 (7 app tables)" test "$(psql_admin -d srcdb -Atc "select count(*) from pg_tables where schemaname='public' and tablename not like '%yoyo%'")" = 7

  psql_old() { psql_admin -d srcdb -At "$@"; }
  unknown=$(audit_sql | psql_old)
  t "audit: a clean app schema reports nothing but the test cluster's superuser" test "$unknown" = "extra role pgadmin (SUPERUSER)"
  psql_admin -d srcdb -c "create function public.kdevtmpfsi() returns int language sql as 'select 1'; create table public.zz_cmd (t text);" >/dev/null
  unknown=$(audit_sql | psql_old)
  t "audit: flags an unexpected function" grep -q 'function public.kdevtmpfsi' <<<"$unknown"
  t "audit: flags an unexpected table" grep -q 'relation public.zz_cmd' <<<"$unknown"
  psql_admin -d srcdb -c "drop function public.kdevtmpfsi(); drop table public.zz_cmd;" >/dev/null

  PGPASSWORD=$ADMINPW "$PGBIN/pg_dump" -h 127.0.0.1 -p "$PGPORT_TEST" -U pgadmin -d srcdb -Fc -f "$P/src.dump"
  psql_old <<<"$COUNTS_SQL" > "$P/counts.old"
  t "COUNTS_SQL: 11 tables and 7 sequences" test "$(grep -vc '^seq:' "$P/counts.old"),$(grep -c '^seq:' "$P/counts.old")" = "11,7"
  t "COUNTS_SQL: exact counts (250 messages)" grep -qx 'messages|250' "$P/counts.old"

  APP_ROLE=jerboa APP_DB=jerboa APP_DB_PASS=$(gen_secret)
  jpw=$APP_DB_PASS
  t "create_role_and_db (password via psql \\getenv, never in argv)" create_role_and_db
  t "restore as non-superuser: --no-owner --no-privileges --role=jerboa, one transaction" restore_dump "$P/src.dump"
  t "every restored object is owned by jerboa" check_app_role_owns_everything
  psql_new <<<"$COUNTS_SQL" > "$P/counts.new"
  t "row counts and sequence values identical after the restore" diff "$P/counts.old" "$P/counts.new"
  t "jerboa: LOGIN, not superuser/createdb/createrole/replication/bypassrls" \
    test "$(psql_admin -d postgres -Atc "select concat_ws(',', rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls) from pg_roles where rolname = 'jerboa'")" = "t,f,f,f,f,f"
  t "jerboa's password is stored as a SCRAM-SHA-256 verifier" \
    test "$(psql_admin -d postgres -Atc "select left(rolpassword, 14) from pg_authid where rolname = 'jerboa'")" = 'SCRAM-SHA-256$'

  jpsql() { PGPASSWORD=$1 "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGPORT_TEST" -U jerboa -d "$2" -v ON_ERROR_STOP=1 -Atc "$3"; }
  t "jerboa logs in over TCP and reads the data" test "$(jpsql "$jpw" jerboa 'select count(*) from users')" = 3
  t "jerboa can write (the app inserts messages)" jpsql "$jpw" jerboa "insert into messages (sender, channel, message) values (1, '1', 'hi')"
  t "jerboa's sequences continue after the old values" test "$(jpsql "$jpw" jerboa "select max(id) from messages")" = 251
  t_fails "a wrong password is rejected" jpsql wrong-password jerboa 'select 1'
  t_fails "jerboa cannot connect to the postgres database" jpsql "$jpw" postgres 'select 1'
  t_fails "jerboa cannot COPY ... FROM PROGRAM (how the miner got in)" jpsql "$jpw" jerboa "copy messages (message) from program 'id'"
  t_fails "jerboa cannot create a C-language function" jpsql "$jpw" jerboa "create function f() returns int as '/lib/x.so', 'f' language c"
  t_fails "jerboa cannot create databases" jpsql "$jpw" jerboa 'create database x'
  t_fails "jerboa cannot create roles" jpsql "$jpw" jerboa 'create role x'

  APP_ROLE=postgres APP_DB=jerboa_legacy APP_DB_PASS=$(gen_secret)
  local lpw=$APP_DB_PASS
  t "--legacy-role-name: creates role 'postgres' + database" create_role_and_db
  t "--legacy-role-name: that 'postgres' is NOT a superuser" \
    test "$(psql_admin -d postgres -Atc "select rolsuper from pg_roles where rolname = 'postgres'")" = f
  t "--legacy-role-name: restore and ownership" restore_dump "$P/src.dump"
  t "--legacy-role-name: counts identical" diff "$P/counts.old" <(psql_new <<<"$COUNTS_SQL")

  if uv run -q --no-project --python 3.12 --with psycopg2-binary python -c 'import psycopg2' 2>/dev/null; then
    # app/database.py today: psycopg2.connect(user="postgres", password=..., host="127.0.0.1")
    t "today's app code (user=postgres hardcoded, no dbname/port) lands in jerboa_legacy via PGDATABASE + PGPORT" \
      env PGDATABASE=jerboa_legacy PGPORT="$PGPORT_TEST" PW="$lpw" uv run -q --no-project --python 3.12 --with psycopg2-binary python -c '
import os, psycopg2
c = psycopg2.connect(user="postgres", password=os.environ["PW"], host="127.0.0.1")
cur = c.cursor(); cur.execute("select current_user, current_database(), (select count(*) from users)")
assert cur.fetchone() == ("postgres", "jerboa_legacy", 3)'
    # the proposed backend change: user/dbname from db_user/db_name
    t "the proposed db_user/db_name code connects as jerboa to jerboa" \
      env db_user=jerboa db_name=jerboa PGPORT="$PGPORT_TEST" db_pass="$jpw" uv run -q --no-project --python 3.12 --with psycopg2-binary python -c '
import os, psycopg2
c = psycopg2.connect(user=os.environ.get("db_user", "postgres"), dbname=os.environ.get("db_name", "postgres"),
                     password=os.environ["db_pass"], host="127.0.0.1")
cur = c.cursor(); cur.execute("select current_user, current_database()")
assert cur.fetchone() == ("jerboa", "jerboa")'
  else
    skip "psycopg2 connection checks (psycopg2-binary not installable)"
  fi

  "$PGBIN/pg_ctl" -D "$P/data" -m fast stop >/dev/null 2>&1
  rm -f "$T/pg.bin"
}

# ---------------------------------------------------------------- git ----

group_git() {
  group "git: resolve_ref"
  export SRC_DIR="$T/git/src"
  git clone -q --no-checkout "$REPO" "$SRC_DIR"
  git -C "$SRC_DIR" fetch -q --tags origin '+refs/heads/*:refs/remotes/origin/*'
  # shellcheck source=../deploy_app.sh
  JERBOA_SOURCE_ONLY=1 source "$DEPLOY/deploy_app.sh"
  local sha tag
  sha=$(git -C "$REPO" rev-parse master)
  tag=$(git -C "$SRC_DIR" tag --points-at "$sha" | head -n1)
  t "branch name -> sha" test "$(resolve_ref master)" = "$sha"
  t "short sha -> full sha" test "$(resolve_ref "${sha:0:7}")" = "$sha"
  if [[ -n $tag ]]; then t "tag -> sha" test "$(resolve_ref "$tag")" = "$sha"; else skip "tag -> sha (no tag on master here)"; fi
  t_fails "unknown ref fails" resolve_ref no-such-branch-or-tag
}

# --------------------------------------------------------------- help ----

group_help() {
  group "--help of every phase script"
  local f
  for f in backup deploy_app deploy_frontend migrate_db harden_nginx ops_hygiene; do
    t "$f.sh --help prints its header" sh -c "bash '$DEPLOY/$f.sh' --help | grep -q '^Phase'"
  done
}

# --------------------------------------------------------------- main ----

run_group group_help
run_group group_env
run_group group_docker
run_group group_backup
run_group group_frontend
if have nginx || [[ -x /opt/homebrew/bin/nginx ]]; then run_group group_nginx; else group nginx; skip "nginx group (no nginx)"; fi
run_group group_daemon
run_group group_postgres
run_group group_git

pass=$(grep -c '^PASS' "$RESULTS")
fail=$(grep -c '^FAIL' "$RESULTS")
skipped=$(grep -c '^SKIP' "$RESULTS")
printf '\n%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skipped"
if (( fail > 0 )); then
  grep '^FAIL' "$RESULTS" | sed 's/^/  /'
  exit 1
fi
