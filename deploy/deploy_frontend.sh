#!/usr/bin/env bash
# Phase 3: deploy a frontend build to /var/www/html. No downtime.
#
#   (laptop)  scp dist.tar.gz root@chat.ipieter.be:/root/jerboa-dist.tar.gz
#   (server)  ./deploy_frontend.sh /root/jerboa-dist.tar.gz
#             ./deploy_frontend.sh --rollback [/var/www/html.bak-<ts>]
#             ./deploy_frontend.sh --list
#   options:  --carry-over   also keep top-level files that only the live site has
#             --yes          do not ask questions
#
# Steps
#   1. Check the tarball: a gzipped tar with no absolute paths, no '..', no links;
#      an index.html at the top or one directory down (dist/); every /js and /css
#      file that index.html references is present; and it is a production build
#      (it talks to https://chat.ipieter.be, not localhost:9000).
#   2. Unpack into /var/www/html.new-<ts> (same filesystem), owner root, 755/644.
#   3. Swap with a single rename(2) using RENAME_EXCHANGE, so there is never a
#      moment without /var/www/html. The old tree becomes /var/www/html.bak-<ts>.
#   4. Verify through the local nginx: / serves exactly the new index.html, every
#      referenced asset returns 200, /api/status still works. If not, swap back.

PHASE=deploy_frontend
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${WEBROOT:=/var/www/html}"
TARBALL=""
MODE=deploy
CARRY_OVER=0
ROLLBACK_TO=""
for arg in "$@"; do
  case $arg in
    --rollback) MODE=rollback ;;
    --list) MODE=list ;;
    --carry-over) CARRY_OVER=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) usage_and_exit ;;
    -*) die "unknown option: $arg (see --help)" ;;
    *)
      if [[ $MODE == rollback ]]; then ROLLBACK_TO=$arg
      else [[ -z $TARBALL ]] || die "only one tarball, please"; TARBALL=$arg; fi ;;
  esac
done

# ------------------------------------------------------------- helpers ----

# Atomically exchange two paths (Linux renameat2 with RENAME_EXCHANGE, kernel
# >= 3.15, ext4). Python 3.6 has no wrapper and glibc 2.27 has none either, so
# this calls the syscall directly. It either swaps both names or changes nothing.
exchange_paths() { # <a> <b>
  python3 - "$1" "$2" <<'PY'
import ctypes, os, sys
nr = {"x86_64": 316, "aarch64": 276}.get(os.uname().machine)
if nr is None:
    sys.exit("renameat2: unknown architecture")
libc = ctypes.CDLL(None, use_errno=True)
libc.syscall.restype = ctypes.c_long
AT_FDCWD, RENAME_EXCHANGE = -100, 2
a, b = (os.fsencode(p) for p in sys.argv[1:3])
res = libc.syscall(ctypes.c_long(nr), ctypes.c_long(AT_FDCWD), ctypes.c_char_p(a),
                   ctypes.c_long(AT_FDCWD), ctypes.c_char_p(b), ctypes.c_long(RENAME_EXCHANGE))
if res != 0:
    sys.exit("renameat2: " + os.strerror(ctypes.get_errno()))
PY
}

# Swap <live> and <staged>. Afterwards <live> has the staged content and
# <staged> holds what used to be live.
swap_dirs() { # <live> <staged>
  if exchange_paths "$1" "$2"; then
    ok "swapped atomically (renameat2 RENAME_EXCHANGE)"
  else
    warn "atomic exchange unavailable; falling back to two renames (a gap of microseconds)"
    local tmp="$1.swap-$$"
    mv "$1" "$tmp" && mv "$2" "$1" && mv "$tmp" "$2"
  fi
}

# Reject anything that could write outside the target directory.
check_tar_listing() { # <tarball>
  local verbose names
  verbose=$(tar -tvzf "$1") || die "$1 is not a readable .tar.gz"
  names=$(tar -tzf "$1")
  if grep -qE '^[lhcbp]' <<<"$verbose"; then
    grep -E '^[lhcbp]' <<<"$verbose" | head -5 >&2
    die "tarball contains links or special files; refusing"
  fi
  if grep -qE '(^/|(^|/)\.\.(/|$))' <<<"$names"; then
    die "tarball contains absolute paths or '..'; refusing"
  fi
  [[ -n $names ]] || die "tarball is empty"
}

# Print the directory (inside <dir>) that contains index.html: <dir> itself,
# or one level down (e.g. dist/).
find_site_root() { # <dir>
  if [[ -f $1/index.html ]]; then printf '%s' "$1"; return 0; fi
  local d found=""
  for d in "$1"/*/; do
    if [[ -f ${d}index.html ]]; then
      [[ -z $found ]] || return 1   # two candidates: ambiguous
      found=${d%/}
    fi
  done
  [[ -n $found ]] && printf '%s' "$found"
}

# /js/... and /css/... files that index.html loads (Vue CLI output).
referenced_assets() { # <index.html>
  grep -oE '(src|href)=["'"'"']?/?(js|css)/[^"'"'"' >]+' "$1" | sed -E 's/^(src|href)=["'"'"']?\/?//' | sort -u
}

validate_site() { # <site-root>
  local root=$1 a nmissing=0 n=0
  [[ -s $root/index.html ]] || die "index.html is missing or empty"
  grep -qE '<div id="?app"?' "$root/index.html" || warn "index.html has no <div id=app>; is this the Vue build?"
  while IFS= read -r a; do
    [[ -n $a ]] || continue
    n=$((n + 1))
    [[ -f $root/$a ]] || { warn "index.html references $a, which is not in the tarball"; nmissing=1; }
  done < <(referenced_assets "$root/index.html")
  (( n > 0 )) || die "index.html references no /js or /css files; not a Vue CLI build?"
  (( nmissing == 0 )) || die "the build is incomplete"
  ok "index.html and all $n referenced js/css files are present"
  if grep -rqs 'localhost:9000' "$root/js"; then
    die "the JS still points at localhost:9000: this is a development build (use npm run build)"
  fi
  if grep -rqs "$PUBLIC_HOST" "$root/js"; then
    ok "production build: the JS talks to $PUBLIC_HOST"
  else
    warn "could not find $PUBLIC_HOST in the JS; check VUE_APP_SERVER_BASE in .env.production"
  fi
}

# Check what nginx actually serves now against <site-root>.
verify_live() { # <site-root>
  local root=$1 served a code bad=0
  served=$(curl -fsS --max-time 10 --resolve "$PUBLIC_HOST:443:127.0.0.1" "https://$PUBLIC_HOST/" | sha256sum | cut -d' ' -f1) || return 1
  if [[ $served != "$(sha256sum < "$root/index.html" | cut -d' ' -f1)" ]]; then
    warn "https://$PUBLIC_HOST/ does not serve the expected index.html"
    return 1
  fi
  ok "https://$PUBLIC_HOST/ serves the expected index.html"
  while IFS= read -r a; do
    [[ -n $a ]] || continue
    code=$(http_code "https://$PUBLIC_HOST/$a" --resolve "$PUBLIC_HOST:443:127.0.0.1")
    [[ $code == 200 ]] || { warn "/$a -> $code"; bad=1; }
  done < <(referenced_assets "$root/index.html")
  (( bad == 0 )) || return 1
  ok "all referenced js/css files return 200"
  code=$(http_code "https://$PUBLIC_HOST/api/status" --resolve "$PUBLIC_HOST:443:127.0.0.1")
  [[ $code == 200 ]] || { warn "/api/status -> $code"; return 1; }
  ok "/api/status -> 200"
}

list_backups() {
  local d
  for d in "$WEBROOT".bak-*; do
    [[ -d $d ]] && printf '  %s  %s\n' "$d" "$(du -sh "$d" | cut -f1)"
  done
  return 0
}

latest_backup() {
  local d last=""
  for d in "$WEBROOT".bak-*; do [[ -d $d ]] && last=$d; done
  printf '%s' "$last"
}

do_rollback() {
  local target=${ROLLBACK_TO:-$(latest_backup)}
  [[ -n $target && -d $target ]] || die "no backup to roll back to (looked for $WEBROOT.bak-*)"
  [[ -f $target/index.html ]] || die "$target has no index.html"
  step "Rollback: $WEBROOT <- $target"
  confirm "Swap $target back in as $WEBROOT?" rollback || die "aborted; nothing changed"
  swap_dirs "$WEBROOT" "$target"
  local parked
  parked="$WEBROOT.rolledback-$(ts_utc)"
  mv "$target" "$parked"
  ok "previous live tree parked as $parked"
  verify_live "$WEBROOT" || warn "verification failed after rollback; check nginx (nginx -t, error log)"
  set_rollback "./deploy_frontend.sh --rollback $parked    # undo this rollback"
  print_rollback
}

# ---------------------------------------------------------------- main ----

# The tests source this file with JERBOA_SOURCE_ONLY=1 to reach the helpers.
if [[ ${JERBOA_SOURCE_ONLY:-0} == 1 ]]; then return 0; fi

require_root
start_log
require_cmds tar curl python3 sha256sum

case $MODE in
  list) step "Frontend backups"; list_backups; exit 0 ;;
  rollback) do_rollback; exit 0 ;;
esac

[[ -n $TARBALL ]] || die "usage: ./deploy_frontend.sh <path-to-dist.tar.gz>   (see --help)"
[[ -f $TARBALL ]] || die "no such file: $TARBALL"

step "Pre-flight"
[[ -d $WEBROOT && ! -L $WEBROOT ]] || die "$WEBROOT is not a plain directory"
size_mb=$(( $(stat -c %s "$TARBALL") / 1024 / 1024 ))
ok "tarball: $TARBALL (${size_mb} MB, sha256 $(sha256sum "$TARBALL" | cut -c1-16)...)"
require_disk_mb "$(dirname "$WEBROOT")" $(( size_mb * 4 + 100 )) "unpacking the build"
check_tar_listing "$TARBALL"
ok "tar listing is clean: $(tar -tzf "$TARBALL" | wc -l) entries, no links, no absolute or '..' paths"

ts=$(ts_utc)
unpack="$WEBROOT.unpack-$ts"
staged="$WEBROOT.new-$ts"
backup="$WEBROOT.bak-$ts"
cleanup_add "rm -rf '$unpack'"

step "Unpacking into $staged"
mkdir -p "$unpack"
tar -xzf "$TARBALL" -C "$unpack" --no-same-owner --no-same-permissions
site=$(find_site_root "$unpack") || die "could not find exactly one index.html (top level or one directory down)"
mv "$site" "$staged"
validate_site "$staged"

top_level() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort; }
extra=$(comm -23 <(top_level "$WEBROOT") <(top_level "$staged") || true)
if [[ -n $extra ]]; then
  if [[ $CARRY_OVER == 1 ]]; then
    log "Carrying over top-level entries the new build does not have:"
    while IFS= read -r e; do
      printf '    %s\n' "$e"
      cp -a "$WEBROOT/$e" "$staged/$e"
    done <<<"$extra"
  else
    warn "these top-level entries are live now but not in the new build. They will stop being"
    warn "served (they stay in $backup). Re-run with --carry-over to keep them:"
    indent <<<"$extra"
  fi
fi

chown -R root:root "$staged"
find "$staged" -type d -exec chmod 755 {} +
find "$staged" -type f -exec chmod 644 {} +

step "Plan"
cat <<EOF
  live now : $WEBROOT  ($(du -sh "$WEBROOT" | cut -f1))
  new      : $staged  ($(du -sh "$staged" | cut -f1))
  backup   : the current tree becomes $backup
  Swap is a single rename; no downtime. Users get the new UI on their next page load.
EOF
confirm "Swap the frontend now?" deploy || { rm -rf "$staged"; die "aborted; nothing changed"; }

swap_dirs "$WEBROOT" "$staged"
mv "$staged" "$backup"
set_rollback "./deploy_frontend.sh --rollback $backup"
ok "previous tree saved as $backup"

step "Verifying through nginx"
if verify_live "$WEBROOT"; then
  step "Done"
  n_backups=$(find "$(dirname "$WEBROOT")" -maxdepth 1 -name "$(basename "$WEBROOT").bak-*" | wc -l)
  if (( n_backups > 3 )); then
    log "There are $n_backups frontend backups; list them with --list and remove old ones with rm -rf."
  fi
  print_rollback
  exit 0
fi

step "Verification FAILED: swapping the previous tree back"
set_rollback ""
swap_dirs "$WEBROOT" "$backup"
mv "$backup" "$WEBROOT.failed-$ts"
verify_live "$WEBROOT" || warn "the old tree does not verify either; check nginx (nginx -t, error log)"
die "frontend deploy failed; the new build is kept in $WEBROOT.failed-$ts"
