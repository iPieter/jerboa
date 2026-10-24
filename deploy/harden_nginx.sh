#!/usr/bin/env bash
# Phase 5: harden nginx. No downtime (graceful reload).
#
#   ./harden_nginx.sh               stage, test, back up, install, reload, verify
#   ./harden_nginx.sh --check       only run the verification against the live site
#   ./harden_nginx.sh --rollback [<backup-dir>]   restore a backup of /etc/nginx
#   options: --yes
#
# Changes
#   * TLS 1.2 + 1.3 only, Mozilla "intermediate" ciphers (no 3DES/CBC), no
#     session tickets: snippets/jerboa-tls.conf replaces certbot's
#     options-ssl-nginx.conf in the chat server block; the http-level
#     ssl_protocols in nginx.conf drops TLSv1/TLSv1.1 too.
#   * Headers: HSTS (max-age=300 to start; raise later), X-Content-Type-Options,
#     Referrer-Policy, X-Frame-Options SAMEORIGIN, Permissions-Policy, and a
#     Content-Security-Policy in Report-Only mode.
#   * server_tokens off; gzip for css/js/json/svg; client_max_body_size 50m;
#     Host/X-Real-IP/X-Forwarded-For/X-Forwarded-Proto to the backend.
#
# Safety
#   1. The new config is first tested as a staged copy (nginx -t -c <copy>), so a
#      bad config never reaches /etc/nginx.
#   2. /etc/nginx is copied to /root/jerboa-state/nginx-backups/<ts>/ before
#      anything is installed.
#   3. nginx -t on the real config; on failure the backup is restored. No reload.
#   4. After the reload: if the site or the API stop answering, the backup is
#      restored and nginx reloaded again.

PHASE=harden_nginx
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${NGINX_DIR:=/etc/nginx}"
SITE_REL=conf.d/www.chat.ipieter.be.conf
BACKUP_ROOT=$STATE_DIR/nginx-backups
FILES=$SCRIPT_DIR/files/nginx

MODE=apply
ROLLBACK_TO=""
for arg in "$@"; do
  case $arg in
    --check) MODE=check ;;
    --rollback) MODE=rollback ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage_and_exit ;;
    -*) die "unknown option: $arg (see --help)" ;;
    *) [[ $MODE == rollback ]] || die "unexpected argument: $arg"; ROLLBACK_TO=$arg ;;
  esac
done

# ------------------------------------------------------------- helpers ----

# First value of a simple directive in a file, e.g. ssl_certificate.
conf_value() { # <directive> <file>
  sed -nE "s/^[[:space:]]*$1[[:space:]]+([^;[:space:]]+)[[:space:]]*;.*/\1/p" "$2" | head -n1
}

# Build the complete new /etc/nginx in <stage> (a copy of the live one).
render_stage() { # <stage-dir> <cert> <key> <dhparam> <tls-protocols>
  local stage=$1
  sed -e "s|@SSL_CERT@|$2|" -e "s|@SSL_KEY@|$3|" -e "s|@SSL_DHPARAM@|$4|" \
      "$FILES/www.chat.ipieter.be.conf.template" > "$stage/$SITE_REL"
  sed -e "s|@TLS_PROTOCOLS@|$5|" "$FILES/jerboa-tls.conf" > "$stage/snippets/jerboa-tls.conf"
  cp "$FILES/jerboa-security-headers.conf" "$stage/snippets/jerboa-security-headers.conf"
  cp "$FILES/jerboa-proxy.conf" "$stage/snippets/jerboa-proxy.conf"
  cp "$FILES/00-jerboa-http.conf" "$stage/conf.d/00-jerboa-http.conf"
  # http-level default for any other TLS server block.
  sed -E "s/^([[:space:]]*)ssl_protocols[[:space:]]+TLSv1[[:space:]]+TLSv1\.1[[:space:]]+TLSv1\.2;.*/\1ssl_protocols $5; # jerboa: TLS 1.0\/1.1 removed/" \
      "$stage/nginx.conf" > "$stage/nginx.conf.new"
  cat "$stage/nginx.conf.new" > "$stage/nginx.conf"   # keeps owner and mode
  rm -f "$stage/nginx.conf.new"
}

# Test a staged tree without touching /etc/nginx: a second copy whose absolute
# /etc/nginx/ paths point into the copy, then nginx -t -c on it.
test_stage() { # <stage-dir>
  local t="$WORK/testroot"
  rm -rf "$t"
  cp -a "$1" "$t"
  grep -rlF "$NGINX_DIR/" "$t" | while IFS= read -r f; do
    sed "s|$NGINX_DIR/|$t/|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  "${NGINX_BIN:-nginx}" -t -q -c "$t/nginx.conf"
}

restore_backup() { # <backup-dir>
  rsync -a --delete "$1/" "$NGINX_DIR/"
  ok "restored $NGINX_DIR from $1"
}

reload_nginx() {
  systemctl reload nginx
  sleep 1
  systemctl is-active --quiet nginx || die "nginx is not active after reload"
}

# The checks that decide whether a reload gets rolled back.
verify_core() {
  local code
  code=$(http_code "https://$PUBLIC_HOST/" --resolve "$PUBLIC_HOST:443:127.0.0.1")
  [[ $code == 200 ]] || { warn "https://$PUBLIC_HOST/ -> $code"; return 1; }
  ok "https://$PUBLIC_HOST/ -> 200"
  code=$(http_code "https://$PUBLIC_HOST/api/status" --resolve "$PUBLIC_HOST:443:127.0.0.1")
  [[ $code == 200 ]] || { warn "/api/status -> $code"; return 1; }
  ok "/api/status -> 200"
  code=$(http_code "http://$PUBLIC_HOST/" --resolve "$PUBLIC_HOST:80:127.0.0.1")
  [[ $code == 301 ]] || { warn "http:// -> $code (expected the 301 to https)"; return 1; }
  ok "http:// -> 301"
}

tls_ok() { # <openssl s_client args...> -> 0 if the handshake succeeds
  local out
  out=$(timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$PUBLIC_HOST" "$@" </dev/null 2>&1 || true)
  grep -q 'Cipher is ' <<<"$out" && ! grep -q 'Cipher is (NONE)' <<<"$out"
}

# Everything else: reported, never rolled back automatically.
verify_details() {
  local hdrs h js fails=0
  hdrs=$(curl -sS -D - -o /dev/null --max-time 10 --resolve "$PUBLIC_HOST:443:127.0.0.1" "https://$PUBLIC_HOST/" | tr -d '\r')
  for h in strict-transport-security x-content-type-options referrer-policy x-frame-options \
           permissions-policy content-security-policy-report-only; do
    if grep -qi "^$h:" <<<"$hdrs"; then ok "header $h"; else warn "missing header $h"; fails=1; fi
  done
  if grep -qiE '^server: nginx/' <<<"$hdrs"; then warn "Server header still shows the version"; fails=1
  else ok "server header: $(grep -i '^server:' <<<"$hdrs" | cut -d' ' -f2-)"; fi

  if tls_ok -tls1_2; then ok "TLS 1.2 accepted"; else warn "TLS 1.2 handshake failed"; fails=1; fi
  if openssl s_client -help 2>&1 | grep -q -- '-tls1_3'; then
    if tls_ok -tls1_3; then ok "TLS 1.3 accepted"; else warn "TLS 1.3 not accepted"; fails=1; fi
  fi
  if tls_ok -tls1_1; then warn "TLS 1.1 is still accepted"; fails=1; else ok "TLS 1.1 refused"; fi
  if tls_ok -tls1; then warn "TLS 1.0 is still accepted"; fails=1; else ok "TLS 1.0 refused"; fi
  if tls_ok -tls1_2 -cipher DES-CBC3-SHA; then warn "3DES is still accepted"; fails=1; else ok "3DES refused"; fi

  js=$(grep -oE '/js/[^"'"'"' >]+\.js' /var/www/html/index.html 2>/dev/null | head -n1 || true)
  if [[ -n $js ]]; then
    if curl -sS -o /dev/null -D - -H 'Accept-Encoding: gzip' --max-time 10 \
         --resolve "$PUBLIC_HOST:443:127.0.0.1" "https://$PUBLIC_HOST$js" | grep -qi '^content-encoding: gzip'; then
      ok "gzip on $js"
    else
      warn "no gzip on $js"; fails=1
    fi
  fi
  return "$fails"
}

latest_backup() {
  local d last=""
  for d in "$BACKUP_ROOT"/*/; do [[ -d $d ]] && last=${d%/}; done
  printf '%s' "$last"
}

# ---------------------------------------------------------------- main ----

# The tests source this file with JERBOA_SOURCE_ONLY=1 to reach the helpers.
if [[ ${JERBOA_SOURCE_ONLY:-0} == 1 ]]; then return 0; fi

require_root
start_log
require_cmds nginx rsync curl openssl systemctl timeout

if [[ $MODE == check ]]; then
  step "Verifying the live site"
  verify_core && verify_details && ok "all checks passed"
  exit
fi

if [[ $MODE == rollback ]]; then
  target=${ROLLBACK_TO:-$(latest_backup)}
  [[ -n $target && -f $target/nginx.conf ]] || die "no nginx backup found in $BACKUP_ROOT"
  step "Rollback: $NGINX_DIR <- $target"
  confirm "Restore $target over $NGINX_DIR and reload?" rollback || die "aborted; nothing changed"
  safety="$BACKUP_ROOT/$(ts_utc)-before-rollback"
  mkdir -p "$safety"
  rsync -a "$NGINX_DIR/" "$safety/"
  restore_backup "$target"
  nginx -t -q || { restore_backup "$safety"; die "restored config fails nginx -t; put the current one back"; }
  reload_nginx
  verify_core || warn "site checks failed after rollback"
  set_rollback "./harden_nginx.sh --rollback $safety    # undo this rollback"
  print_rollback
  exit 0
fi

step "Pre-flight"
nginx -t -q 2>/dev/null || die "the CURRENT nginx config already fails nginx -t; fix that first"
ok "current config passes nginx -t"
site="$NGINX_DIR/$SITE_REL"
[[ -f $site ]] || die "$site not found"
cert=$(conf_value ssl_certificate "$site")
key=$(conf_value ssl_certificate_key "$site")
dhparam=$(conf_value ssl_dhparam "$site")
for f in "$cert" "$key" "$dhparam"; do
  [[ -n $f && -f $f ]] || die "could not find the certificate/key/dhparam files referenced in $site"
done
ok "certificate $cert (expires $(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2))"
if nginx -V 2>&1 | grep -qE 'built with OpenSSL (1\.1\.[1-9]|[3-9]\.)'; then
  tls_protocols="TLSv1.2 TLSv1.3"
  ok "nginx is built with OpenSSL >= 1.1.1: enabling TLS 1.3"
else
  tls_protocols="TLSv1.2"
  warn "nginx is built against an older OpenSSL: TLS 1.2 only"
fi
# Locations in the live file that the template would drop.
while IFS= read -r loc; do
  grep -qF "location $loc " "$FILES/www.chat.ipieter.be.conf.template" ||
    die "the live config has 'location $loc', which the template does not; add it to files/nginx/www.chat.ipieter.be.conf.template first"
done < <(sed -nE 's/^[[:space:]]*location[[:space:]]+([^[:space:]{]+).*/\1/p' "$site")
ok "the template keeps every location of the live config (/, /emoji/, /api/, /socket.io/)"

WORK=$(mktemp -d)
cleanup_add "rm -rf '$WORK'"
stage="$WORK/stage"
cp -a "$NGINX_DIR" "$stage"
render_stage "$stage" "$cert" "$key" "$dhparam" "$tls_protocols"

step "Changes (diff of $NGINX_DIR -> new)"
if diff -ruN "$NGINX_DIR" "$stage" > "$WORK/nginx.diff"; then
  ok "nothing to change; the hardened config is already installed"
  step "Verifying the live site"
  verify_core && verify_details && ok "all checks passed"
  exit 0
fi
sed "s|$stage|(new)|g" "$WORK/nginx.diff" | sed 's/^/    /'

step "Testing the staged config (nginx -t on a copy; /etc/nginx untouched)"
if test_stage "$stage"; then
  ok "staged config passes nginx -t"
else
  die "staged config fails nginx -t (output above); nothing was changed"
fi

confirm "Install this config and reload nginx?" harden || die "aborted; nothing changed"

step "Backing up $NGINX_DIR"
backup="$BACKUP_ROOT/$(ts_utc)"
mkdir -p "$backup"
chmod 700 "$STATE_DIR" "$BACKUP_ROOT"
rsync -a "$NGINX_DIR/" "$backup/"
ok "backup: $backup"
set_rollback "./harden_nginx.sh --rollback $backup
# by hand:  rsync -a --delete $backup/ $NGINX_DIR/ && nginx -t && systemctl reload nginx"

step "Installing"
rsync -a --checksum "$stage/" "$NGINX_DIR/"
if ! nginx -t; then
  warn "nginx -t failed on the installed config; restoring the backup"
  set_rollback ""
  restore_backup "$backup"
  nginx -t -q && ok "backup config passes nginx -t again (nginx was never reloaded)"
  die "hardening not applied"
fi
ok "nginx -t passed"

step "Reloading nginx (graceful)"
reload_nginx
ok "reloaded"

step "Verifying"
if ! verify_core; then
  warn "the site broke after the reload; restoring the backup"
  set_rollback ""
  restore_backup "$backup"
  nginx -t -q && reload_nginx
  verify_core || warn "still failing after restoring the backup; check $NGINX_DIR and the error log"
  die "hardening rolled back"
fi
verify_details || warn "some details are not as expected (see above); the site itself works"

step "Done"
cat <<EOF
  Next:
  * Renewal check (talks to Let's Encrypt staging, briefly edits and reloads nginx):
        certbot renew --dry-run
  * Browse the chat with devtools open for a few days and read the console for
    CSP reports; then enforce it (see snippets/jerboa-security-headers.conf).
  * Raise HSTS max-age step by step (same file).
  * External check: https://www.ssllabs.com/ssltest/analyze.html?d=$PUBLIC_HOST
EOF
print_rollback
