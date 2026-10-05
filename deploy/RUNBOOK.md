# Jerboa redeploy runbook (post-incident)

Host: `root@chat.ipieter.be` (Ubuntu 18.04, 1 vCPU, 985 MB RAM, no swap).

This runbook redeploys the chat after the October 2026 compromise of the Postgres
container (Kinsing miner plus a backdoor superuser). It assumes the containment
script has already run: malware removed, backdoor role dropped,
`listen_addresses='localhost'`, the `host all all all md5` line gone, a random
postgres password set, and the two attacker IPs blocked in ufw.

Every phase is a separate script in `deploy/`. Each one runs pre-flight checks
before it changes anything, asks before the disruptive step, writes a
transcript to `/root/jerboa-state/logs/`, and prints its rollback command at
the end. Every script also has `--help`.

## Order and downtime

| # | Script | Downtime | What changes | Rollback |
|---|--------|----------|--------------|----------|
| 1 | `backup.sh` | none | DB dump now; nightly dump + uploads snapshot (systemd timer, 14 days) | `./backup.sh --uninstall` |
| 2 | `deploy_app.sh <ref>` | 10-30 s of API | backend container rebuilt from git (code only), secrets in `/root/jerboa.env`, **new flask_secret: everyone signs in again** | `./deploy_app.sh --rollback` |
| 3 | `deploy_frontend.sh <tar.gz>` | none | `/var/www/html` swapped atomically | `./deploy_frontend.sh --rollback` |
| 4 | `migrate_db.sh` (`--rehearse` first) | 2-5 min (rehearsal: none) | fresh Postgres 16 container, non-superuser app role, compromised container stopped | `./migrate_db.sh --rollback` |
| 5 | `harden_nginx.sh` | none (graceful reload) | TLS 1.2/1.3, security headers, CSP report-only, gzip, 50m body limit | `./harden_nginx.sh --rollback` |
| 6 | `ops_hygiene.sh` | none | logrotate, journald cap, docker log defaults, prune old containers | `./ops_hygiene.sh --rollback` |
| - | upgrade and reboot (by hand) | 2-5 min | kernel 4.15.0-213 and pending updates | none (see below) |

Phase 2 has to come before phase 4: the migration switches the app over through
`/root/jerboa.env`, which phase 2 creates. Phase 3 can run whenever the
frontend build is ready. Run phase 5 after phase 3, so you test the CSP with the
new frontend.

## What the inspection found (and how the scripts handle it)

Checked read-only on 2026-10-05. These findings shaped the scripts:

- **pipenv in the image overrides `--env-file`.** The image has pipenv
  2018.11.26, which loads `/chat_app/.env` with `override=True`. That `.env` is
  baked into `chat:latest` and contains the old `db_pass` and `flask_secret`.
  Running the old image with `--env-file` would therefore **silently keep the
  old flask_secret**. The new image deletes `/chat_app/.env` and sets
  `PIPENV_DONT_LOAD_ENV=1`. After a deploy, `deploy_app.sh` also checks that
  the running process has exactly the values from `/root/jerboa.env`. It
  compares hashes and prints only match or mismatch.
- **The running `server.py` was hand-patched and differs from master.** It has
  `from werkzeug.utils import secure_filename`; master's
  `from werkzeug import secure_filename` crashes on Werkzeug 1.0.1, which the
  image ships. It also has `SocketIO(..., ping_timeout=10, ping_interval=5)`.
  The backend branch needs both (see "Backend contract"). `deploy_app.sh` warns
  if a ref lacks them, and its smoke test catches the import error before
  anything is stopped.
- **Undeployed edit in `/root/chat`.** `/root/chat/app/database.py` has an
  edit from November 2024 that never reached the running image or master: the
  message page size went from `LIMIT 30` to `LIMIT 1000`. Decide whether you
  want it.
- **The app hardcodes `user="postgres"`.** `app/database.py` calls
  `psycopg2.connect(user="postgres", password=..., host="127.0.0.1")` with no
  database name, so it uses the database `postgres`. A non-superuser role
  needs a code change; see "Backend contract". Until then, the migration can
  run with `--legacy-role-name`.
- **The official postgres image trusts 127.0.0.1 by default.** Its initdb
  writes `host all all 127.0.0.1/32 trust`. With `--network host`, every
  process on the droplet could then log in as superuser without a password.
  The old cluster still has that line. The new one is initialised with
  `--auth-host=scram-sha-256 --auth-local=trust`, so every TCP login needs a
  password, and the script verifies `pg_hba.conf` before it continues. Local
  trust only covers the Unix socket inside the container, which you can reach
  only through `docker exec`.
- **The 2019 postgres image predates `STOPSIGNAL SIGINT`.** `docker stop`
  waits for clients and then SIGKILLs, and the app's connection sits idle in a
  transaction forever. The containment restart did exactly that: the log
  shows "database system was not properly shut down; automatic recovery". The
  scripts stop the app first and then send SIGINT (fast shutdown).
- **The uploads are 2.3 GB, and 7.4 GB of disk is free.** Fourteen nightly
  tarballs would need about 32 GB. The nightly job therefore takes rsync
  snapshots with hard links: every night looks like a full copy, but unchanged
  files are stored once. Fourteen days cost about 2.3 GB plus that period's new
  uploads. `UPLOADS_MODE=tar` exists for a bigger disk.
- **The nginx logs are not where logrotate looks.** The chat logs to
  `/root/chat/logs/nginx_{access,error}.log`, not `/var/log/nginx`, so they were
  never rotated (632 MB). `ops_hygiene.sh` adds a logrotate entry for that
  path.
- **TLS 1.3 is possible.** nginx 1.14 here is built against OpenSSL 1.1.1. The
  certificate covers only `chat.ipieter.be` (not `www.chat.`), so HSTS gets no
  `includeSubDomains`. Certbot uses the nginx authenticator and installer;
  renewals only reload nginx and do not re-add `options-ssl-nginx.conf`.
- **The PDF preview needs same-origin framing.** It loads `/api/files?show=1`
  in a same-origin iframe, so the scripts send `X-Frame-Options: SAMEORIGIN`
  (not DENY) and `frame-src 'self'`. KaTeX and Chart.js need
  `style-src 'unsafe-inline'`. The build has no inline scripts.
- **The old DB schema is clean.** It has the 7 app tables, 4 yoyo tables and 7
  sequences, with no functions, triggers, extensions or extra roles (after
  containment). `migrate_db.sh` repeats this audit and stops if that changes.
- **Docker is 20.10.21 from Ubuntu's `docker.io`, without compose.**
  unattended-upgrades can upgrade it, which restarts dockerd. Containers with
  `--restart unless-stopped` come back after that; the old hand-started ones
  (restart policy `no`) would not.
- **Port 9000 is bound on 0.0.0.0.** The backend hardcodes
  `host="0.0.0.0"`; only ufw keeps it private. `starling-relay` on 9101 is
  open to the world (see the checklist).

## Before you start

```bash
ssh root@chat.ipieter.be
tmux new -s jerboa-ops          # an SSH drop must not kill a running migration
                                # (reattach: tmux attach -t jerboa-ops; leave starling's session alone)
git clone --branch ops-runbook https://github.com/iPieter/jerboa.git /root/jerboa-ops
cd /root/jerboa-ops/deploy
```

(After the PR is merged: `--branch master`. To update later, run
`git -C /root/jerboa-ops pull`.)

Every script accepts `--help`. Scripts ask before disruptive steps; `--yes`
skips the questions. The exception is container pruning, which always asks.

Where things live:

| Path | What |
|------|------|
| `/root/jerboa.env` | backend secrets (0600): `db_pass`, `flask_secret`, after phase 4 also `db_user`, `db_name`, `PGDATABASE` |
| `/root/jerboa-db-admin.env` | Postgres 16 superuser `pgadmin` (0600), used for TCP logins only |
| `/root/jerboa-state/` | state between runs, config backups, dated copies of secret files, `logs/` transcripts |
| `/root/jerboa-src/` | the checkout that `deploy_app.sh` builds from |
| `/root/backups/` | `db/*.dump`, `uploads/<ts>/`, `LAST_SUCCESS` |

---

## Phase 1: backups

No downtime.

```bash
./backup.sh
```

The script:

1. finds the running Postgres container;
2. dumps the `postgres` database to
   `/root/backups/db/jerboa-db-<UTC ts>.dump` (custom format), reads it back
   with `pg_restore -l` and writes a `.sha256`;
3. installs `/usr/local/sbin/jerboa-backup`, `jerboa-backup.service` and
   `jerboa-backup.timer` (nightly around 03:15 UTC) with the settings in
   `/etc/jerboa-backup.conf`;
4. offers to run the full job right away. The first uploads snapshot copies
   about 2.3 GB, which takes a few minutes. Otherwise tonight's run takes it.
   Use `--full-now` to run it without the question.

**Success looks like:**

- `ok  dump: /root/backups/db/jerboa-db-…dump (…), sha256 …`
- `ok  jerboa-backup.timer is active:` followed by the next run time
- the next day, `cat /root/backups/LAST_SUCCESS` shows last night's timestamp

**Check later:**

```bash
systemctl list-timers jerboa-backup.timer
journalctl -u jerboa-backup --since yesterday
ls -lh /root/backups/db | tail
```

**Restore drills:**

```bash
# list the contents of a dump (read-only)
docker exec -i naughty_rubin pg_restore -l < /root/backups/db/jerboa-db-<ts>.dump | head
# after phase 4, into the new cluster (CAREFUL: --clean replaces live data)
docker exec -i jerboa-db pg_restore -U pgadmin -d jerboa --clean --if-exists \
  --no-owner --no-privileges --role=jerboa < /root/backups/db/jerboa-db-<ts>.dump
# uploads
rsync -a /root/backups/uploads/latest/chat_images/ /root/chat_images/
```

**Off-box copies (your choice; nothing leaves the server yet):**

1. Pull from your laptop. This needs no credentials on the server, so it is
   the safest option against a future intruder.

   ```bash
   rsync -av  root@chat.ipieter.be:/root/backups/db/ ~/jerboa-backups/db/
   rsync -avH root@chat.ipieter.be:/root/backups/uploads/latest/ ~/jerboa-backups/uploads/
   # or one tarball, streamed, using no disk on the server:
   ssh root@chat.ipieter.be 'tar -C /root/backups/uploads/latest -cf - .' > uploads-$(date +%F).tar
   ```

2. DigitalOcean droplet backups: weekly whole-disk images for +20% of the
   droplet price. Enable them in the control panel; you only click once.
3. Automated push to object storage (DO Spaces, Backblaze B2, S3) with restic
   or rclone, called from `jerboa-backup.sh`. Outbound 443 is open. Use an
   append-only or write-only key, so whoever controls the server cannot delete
   the history.

Recommendation: 1 now, plus 2, then 3 once the dust settles. Set
`HEALTHCHECK_URL` in `/etc/jerboa-backup.conf` (for example a free
healthchecks.io check) so you hear about it when backups stop.

**Rollback:**

```bash
./backup.sh --uninstall
```

This removes the timer, the service and the job. The backups and the config
stay.

---

## Phase 2: backend

About 10-30 s of API downtime.

```bash
./deploy_app.sh security-fixes          # or a tag / commit sha
```

The script:

1. fetches the ref into `/root/jerboa-src` and shows how `app/` differs from the
   running container (full diff in `/root/jerboa-state/deploy-<sha>.diff`). It
   warns if `run.py`, `Pipfile.lock` or `migrations/` changed;
2. builds `chat:<sha12>` as `FROM chat:latest`, then deletes the old `app/`
   and the baked-in `.env`, copies the new `app/` (and `run.py` only if it
   changed), and sets `PIPENV_DONT_LOAD_ENV=1`. Python 3.6 and every
   dependency stay as they are; the build has no network access;
3. on the first run, creates `/root/jerboa.env` (0600). `db_pass` is copied
   from the image's `.env` without being printed; `flask_secret` is newly
   generated. Later runs reuse the file (`--rotate-flask-secret` replaces the
   secret);
4. **smoke test**: imports the new code in a throwaway container against the
   live database. Import errors, a missing variable or a DB problem stop the
   deploy here, while the old container keeps serving;
5. asks (type `deploy`), stops the old container (kept for rollback) and
   starts `jerboa-app-<sha12>` with the same two mounts, `--network host`,
   `--env-file /root/jerboa.env`, `--restart unless-stopped` and json-file log
   caps of 10 MB x 3;
6. runs the health check: `GET /status`, `GET /files?f=<nonexistent>`
   (must return 404, which proves a real DB query works), the socket.io
   polling handshake, and `/api/status` through nginx. It then checks that the
   running process got the values from `/root/jerboa.env`. **If anything
   fails, the old container is started again automatically.**

**Expect after the first run:** every user is signed out and has to sign in
again, because tokens signed with the old secret no longer validate. The iOS
app signs in again by itself. Before phase 4 the old DB still trusts
127.0.0.1, so `db_pass` is not actually checked yet.

**Success looks like:**

- `ok  new code imports, finds its env vars and connects to the database`
- `ok  GET /status -> {"backend": 0, "database": [0, 1]}`, `… -> 404 (database query path works)`, `socket.io polling handshake works`, `… through nginx -> 200`
- `ok  runtime env: db_pass matches /root/jerboa.env` (and the same for `flask_secret`)
- `==> Done: jerboa-app-<sha> is serving`

```bash
./deploy_app.sh --status        # what runs, history, health check
docker logs -f --tail 50 jerboa-app-<sha>
```

**Rollback:**

```bash
./deploy_app.sh --rollback      # stop current, start the previous container (silly_curran on the first run)
# by hand: docker stop jerboa-app-<sha>; docker start silly_curran
```

Rolling back to `silly_curran` means the old `flask_secret` from its baked
`.env`, so users sign in once more. **After phase 4**, do not roll back to a
container that predates the migration: it points at the old database. Deploy
the older code against the current env file instead:
`./deploy_app.sh <old-sha>`.

**Schema migrations:** the script never applies yoyo migrations; it only warns
when a ref brings new ones. Apply them by hand after a backup:

```bash
docker exec -it jerboa-app-<sha> pipenv run yoyo apply -b --database 'postgresql://<db_user>:<db_pass>@127.0.0.1/<db_name>' ./migrations
```

---

## Phase 3: frontend

No downtime.

```bash
# on your laptop, in the frontend build output:
tar -czf jerboa-dist.tar.gz -C dist .
scp jerboa-dist.tar.gz root@chat.ipieter.be:/root/
# on the server:
./deploy_frontend.sh /root/jerboa-dist.tar.gz
```

The script:

1. refuses tarballs with absolute paths, `..`, symlinks, hard links or device
   files;
2. accepts `index.html` at the top or under `dist/`;
3. checks that every `/js` and `/css` file referenced by `index.html` is
   present and that the JS points at `chat.ipieter.be`, not `localhost:9000`;
4. unpacks into `/var/www/html.new-<ts>` as root-owned 755/644 files;
5. lists top-level entries that only the live site has. Today those are
   `socket.io.js`, `katex.min.css` and `index.nginx-debian.html`. They stop
   being served; `--carry-over` keeps them;
6. asks (type `deploy`) and swaps the directories with one `renameat2`
   `RENAME_EXCHANGE`. The old tree becomes `/var/www/html.bak-<ts>`;
7. verifies through nginx that `/` serves exactly the new `index.html`, every
   asset returns 200, and `/api/status` still works. **If not, it swaps back
   automatically.**

**Success looks like:**

- `ok  swapped atomically (renameat2 RENAME_EXCHANGE)`
- `ok  https://chat.ipieter.be/ serves the expected index.html`
- `ok  all referenced js/css files return 200`

**Rollback:**

```bash
./deploy_frontend.sh --rollback                         # newest backup
./deploy_frontend.sh --rollback /var/www/html.bak-<ts>  # a specific one
./deploy_frontend.sh --list
```

---

## Phase 4: database to Postgres 16

The rehearsal has no downtime; the migration takes 2-5 minutes.

**First check which backend runs.** If phase 2 deployed code that reads
`db_user` and `db_name` (see "Backend contract"), use the normal mode. If the
running code still hardcodes `user="postgres"`, add `--legacy-role-name` to
every command below. The pre-flight tells you which case you are in.

```bash
./migrate_db.sh --rehearse              # no downtime, no changes; repeat until it passes
./migrate_db.sh                         # the real thing (asks; type 'migrate')
```

**Rehearsal** (about 1-2 minutes, needs about 250 MB free RAM):

1. dumps the live DB;
2. restores it into a throwaway PG16 on 127.0.0.1:55432 with the exact role,
   database and restore steps of the real run;
3. compares counts. Small differences are normal if people chat meanwhile;
4. lets the **current backend image** query the copy as the new role, through
   `PGPORT`;
5. removes everything again.

**Migration:**

0. Pre-flight, no downtime:
   - finds the old DB and app containers;
   - checks that the app code can use another DB user;
   - audits the old DB for objects the app did not create. This stops on
     functions, triggers, extra tables, extensions or roles; inspect them, or
     pass `--accept-unknown-objects`;
   - pulls `postgres:16` and checks disk space.
1. Stops the backend; **downtime starts**.
2. Dumps the old DB with a clean `pg_dump` from the `postgres:16` image (not
   the compromised container's binaries) to
   `/root/backups/db/premigrate-pg11-<ts>.dump`. It records exact row counts
   and sequence values.
3. Stops the old container with SIGINT (fast shutdown) to free RAM. The
   container is kept, with restart policy `no`.
4. Starts `jerboa-db` (`postgres:16`):
   - `--network host`, `listen_addresses=localhost`, data in `/root/pgdata16`;
   - scram-sha-256 on every TCP line, superuser `pgadmin`;
   - `--restart unless-stopped` and log caps.

   It verifies `pg_hba.conf`, `listen_addresses`, `password_encryption`, and
   that the server listens on loopback only.
5. Creates role `jerboa` (LOGIN; no superuser, createdb, createrole,
   replication or bypassrls; connection limit 10) with a generated password,
   and database `jerboa` owned by it. Revokes `CONNECT` on `postgres` and
   `template1` from PUBLIC. Restores with
   `--no-owner --no-privileges --role=jerboa --single-transaction`, checks
   that `jerboa` owns everything, and compares counts and sequences, which
   must match exactly.
6. Writes `db_user`, `db_name`, `PGDATABASE` and the new `db_pass` into
   `/root/jerboa.env` (copy kept in `/root/jerboa-state/`). Recreates the app
   container from the same image, because env files are only read when a
   container is created. Runs the health check and the runtime env check;
   **downtime ends**.
7. Points `/etc/jerboa-backup.conf` at `jerboa-db` and takes a first dump.

**A failure in steps 1-6 rolls back automatically:**

- the old env file comes back;
- PG16 is stopped and renamed `jerboa-db-failed-<ts>`;
- `/root/pgdata16` is moved to `/root/pgdata16.failed-<ts>`;
- the old DB starts again and the app is recreated.

**Success looks like:**

- `ok  PG 16.x: listen_addresses=localhost, scram-sha-256 on every TCP line, loopback only`
- `ok  every object in public is owned by jerboa`
- `ok  row counts and sequence values match exactly`
- the health check lines and the runtime env lines, as in phase 2
- `==> Done: the chat runs on postgres:16 (postgres@sha256:…)`

```bash
./migrate_db.sh --status
docker exec -it jerboa-db psql -U pgadmin -d jerboa       # admin shell (local socket)
```

**If you restart `jerboa-db`, restart the app afterwards.** The backend keeps a
single connection and never reconnects: `docker restart jerboa-app-<sha>`.

**Rollback** (any time later):

```bash
./migrate_db.sh --rollback
```

This dumps PG16 to `/root/backups/db/pg16-before-rollback-<ts>.dump` first.
It then stops the app and `jerboa-db` (both kept), restores the pre-migration
env file, starts the old container and recreates the app. **Anything written
since the migration exists only in that dump**, not in the old DB.

**Legacy-role mode (`--legacy-role-name`).** The app role in the new cluster is
literally called `postgres`, but it is **not** a superuser: the superuser is
`pgadmin`. The database is `jerboa`, and libpq picks it up from `PGDATABASE`
because the code passes no database name. Once a backend that reads `db_user`
and `db_name` is deployed, switch to the proper name (SCRAM passwords survive
a rename):

```bash
docker exec -it jerboa-db psql -U pgadmin -d postgres -c 'ALTER ROLE postgres RENAME TO jerboa'
sed -i 's/^db_user=postgres$/db_user=jerboa/' /root/jerboa.env
./deploy_app.sh <ref> --force          # recreates the container with the new env
```

### After phase 4: removing the compromised container (after a quiet week)

```bash
docker rm naughty_rubin                                   # the compromised container
tar -C /root/chat -czf /root/forensics-pgdata11-$(date +%F).tgz data   # keep for the incident review
rm -rf /root/chat/data                                    # the old data dir (uid 999)
docker rmi postgres:latest                                # the 2019 image
rm -rf /root/pgdata16.failed-* 2>/dev/null; docker rm jerboa-db-failed-* 2>/dev/null
```

`ops_hygiene.sh --prune-only --include-old-db` also offers the container.

---

## Phase 5: nginx hardening

No downtime (graceful reload).

```bash
./harden_nginx.sh
```

The script:

1. checks that the current config passes `nginx -t` and finds the certificate,
   key and dhparam paths;
2. builds the new `/etc/nginx` as a staged copy and shows the diff;
3. **tests the staged copy with `nginx -t` before touching `/etc/nginx`**;
4. asks (type `harden`) and backs up `/etc/nginx` to
   `/root/jerboa-state/nginx-backups/<ts>/`;
5. installs and runs `nginx -t` again. If that fails, it restores the backup;
   nginx is never reloaded;
6. reloads. If `/`, `/api/status` or the http to https redirect then stop
   working, it restores and reloads again.

What changes:

- `snippets/jerboa-tls.conf` replaces certbot's `options-ssl-nginx.conf` in
  the server block. TLS 1.2 and 1.3 only, with Mozilla's "intermediate"
  ciphers (AEAD with forward secrecy; no 3DES or CBC) and no session tickets.
  The http-level `ssl_protocols` in `nginx.conf` drops TLS 1.0/1.1 too.
- `snippets/jerboa-security-headers.conf`:
  - `Strict-Transport-Security: max-age=300`;
  - `X-Content-Type-Options: nosniff`;
  - `Referrer-Policy: strict-origin-when-cross-origin`;
  - `X-Frame-Options: SAMEORIGIN`;
  - `Permissions-Policy`;
  - `Content-Security-Policy-Report-Only`.
- `snippets/jerboa-proxy.conf` sends `Host`, `X-Real-IP`, `X-Forwarded-For`
  and `X-Forwarded-Proto` to the backend, for `/api/`, `/emoji/` and
  `/socket.io/`.
- `conf.d/00-jerboa-http.conf` sets `server_tokens off` and gzip for
  css, js, json and svg.
- `client_max_body_size` goes from 256M to 50m.

**Success looks like:** `ok` for `/`, `/api/status` and `http:// -> 301`; for
each header; for "TLS 1.2 accepted", "TLS 1.3 accepted", "TLS 1.1 refused",
"TLS 1.0 refused" and "3DES refused"; and for "gzip on /js/…". Re-check any
time with `./harden_nginx.sh --check`.

**Then:**

1. Run `certbot renew --dry-run`. It talks to Let's Encrypt staging and briefly
   edits and reloads nginx; this confirms renewals still work with the new
   config. The certificate expires on Dec 15 and the timer renews 30 days
   before that.
2. Check the CSP. Use the chat for a few days with devtools open and do
   everything once: messages, LaTeX, PDF preview, image upload, emoji, settings,
   the admin charts. Watch the console for `[Report Only]` messages, then
   rename the header to `Content-Security-Policy` in
   `/etc/nginx/snippets/jerboa-security-headers.conf` and run
   `nginx -t && systemctl reload nginx`.
3. Raise HSTS step by step: 86400 (1 day), then 604800 (1 week), then
   31536000 (1 year). The comments in the same file explain it.
4. Get an external grade at
   https://www.ssllabs.com/ssltest/analyze.html?d=chat.ipieter.be

**Rollback:**

```bash
./harden_nginx.sh --rollback                       # newest backup
# by hand: rsync -a --delete /root/jerboa-state/nginx-backups/<ts>/ /etc/nginx/ && nginx -t && systemctl reload nginx
```

---

## Phase 6: ops hygiene

No downtime; only journald restarts.

```bash
./ops_hygiene.sh
```

1. **logrotate** for `/root/chat/logs/nginx_{access,error}.log`: daily, 14
   days, gzip. The config is validated with `logrotate -d`. The script offers
   a first rotation now. The 632 MB access log becomes
   `nginx_access.log-<date>` and is kept 14 days; copy it elsewhere if you want
   it for the incident review.
2. **journald**: `SystemMaxUse=300M` (the journal is 1.5 GB today), then a
   vacuum.
3. **Docker defaults** in `/etc/docker/daemon.json`: json-file, 10m x 3. The
   file is validated as JSON first, because a broken file stops dockerd from
   starting after a reboot. Docker is **not** restarted: dockerd reads the
   file at its next start, and it applies only to containers created after
   that. The containers from phases 2 and 4 already set these options
   explicitly.
4. **Prune**: lists exited containers with their log sizes (about 20
   containers, about 6.3 GB), leaving out rollback targets: the previous app
   container, the pre-migration DB, and `jerboa-db`. It removes them only
   after you type `prune`, even with `--yes`. It uses `docker rm` without
   `-v`, so volumes and bind-mounted data stay. Afterwards it offers to prune
   dangling images.

**Rollback:**

```bash
./ops_hygiene.sh --rollback
```

This removes the logrotate and journald files and restores `daemon.json`.
Pruned containers do not come back.

---

## By hand: upgrade and reboot

About 2-5 minutes of downtime. This is not automated: an interactive dist
upgrade on a 4-year-uptime 18.04 box deserves a human watching it.

```bash
# 0. fresh backup and, ideally, a DigitalOcean snapshot from the control panel
systemctl start jerboa-backup && cat /root/backups/LAST_SUCCESS

# 1. optional but recommended: Ubuntu Pro (free for personal use) for ESM security
#    updates; 18.04 standard support ended in May 2023
pro attach <token-from-ubuntu.com/pro>

# 2. look, then upgrade (keep your modified config files when asked; nginx especially)
apt-get update
apt list --upgradable
apt-get -o Dpkg::Options::=--force-confold dist-upgrade

# 3. starling-relay runs by hand in tmux and will NOT come back after the reboot.
#    Note how it is started first:
tmux ls; ps -o pid,args -C starling-relay

# 4. reboot
reboot

# 5. afterwards
uname -r                                  # 4.15.0-213-generic (or newer)
docker ps                                 # jerboa-app-<sha> and jerboa-db: Up
cd /root/jerboa-ops/deploy && ./deploy_app.sh --status && ./harden_nginx.sh --check
systemctl list-timers jerboa-backup.timer
# start starling-relay again the way it was started before
```

If the app comes up before Postgres after a reboot, it exits and Docker
restarts it (`unless-stopped`) until the database answers.

---

## Backend contract (for the `security-fixes` branch)

The deploy scripts assume the following of `app/`; it must still run on the
existing image (Python 3.6, the 2020 dependency set):

1. **DB user and database from the environment, with the current defaults:**

   ```python
   # app/database.py
   self.conn = psycopg2.connect(
       user=os.environ.get("db_user", "postgres"),
       dbname=os.environ.get("db_name", "postgres"),
       password=password,
       host=os.environ.get("db_host", "127.0.0.1"),
   )
   ```

   The names are lowercase like `db_pass`. `migrate_db.sh` looks for the
   string `db_user` in `app/database.py`; if the branch picks other names,
   change `DB_USER_VAR`/`DB_NAME_VAR` at the top of `migrate_db.sh`. Do not
   pass `port=`: the rehearsal points the app at 127.0.0.1:55432 through
   libpq's `PGPORT`.
2. **Keep the two hand fixes from the running server:**
   `from werkzeug.utils import secure_filename` (Werkzeug 1.0.1 has no
   `werkzeug.secure_filename`) and
   `SocketIO(app, ..., ping_timeout=10, ping_interval=5)`.
3. **No new dependencies.** `deploy_app.sh` copies only `app/` (and `run.py`
   if it changed) and warns if `Pipfile.lock` differs.
4. Nice to have:
   - read the client IP from `X-Forwarded-For` (nginx sends it now), e.g.
     with `werkzeug.middleware.proxy_fix.ProxyFix(app.wsgi_app, x_for=1)`,
     which exists in Werkzeug 1.0;
   - bind to 127.0.0.1 instead of 0.0.0.0.

Issues noticed in passing, for the backend owners:

- The socket.io `connect` handler joins every client, authenticated or not,
  to room `"1"` (General).
- `GET /files` is unauthenticated (it relies on the unguessable id) and serves
  uploads inline with the type libmagic detects, so an uploaded HTML or SVG
  file runs in the chat's origin.
- CORS and socket.io allow `*`.

## Post-incident checklist

- [ ] **Tell every user to change their password**, and to change it anywhere
      else they reused it. The attacker was superuser on the database and
      could read the password hashes. The flask_secret rotation in phase 2
      already signed everyone out.
- [ ] **Audit the 8 SSH keys** in `/root/.ssh/authorized_keys`:
      `ssh-keygen -lf /root/.ssh/authorized_keys` prints fingerprints and
      comments; remove any you cannot name. Also check
      `grep -E '^(PasswordAuthentication|PermitRootLogin)' /etc/ssh/sshd_config`
      (want `no` and `prohibit-password`), `ls /home/*/.ssh` and
      `last -a | head -50`.
- [ ] **starling-relay**: `/starling/starling-relay` runs **as root** in
      tmux, on 9101, **open to the internet** (ufw allows 9101 from anywhere).
      Find out what it is and whether it is current; restrict 9101 in ufw if
      you can; give it its own user and a systemd unit so it survives reboots.
      The scripts do not touch it.
- [ ] **Look for persistence outside the container.** The attacker ran as uid
      999 inside a container whose data dir is a host bind mount:
      `find / -xdev -uid 999 -not -path '/root/chat/data/*' -not -path '/root/chat_data/*' 2>/dev/null`
      (`/root/chat_data` is an older, unused PG data dir from 2019), root
      and user crontabs (`crontab -l`, `/etc/cron.*`), new systemd units
      (`ls -lt /etc/systemd/system | head`), and outbound connections
      (`ss -tnp state established`).
- [ ] **Enable DigitalOcean backups**, and consider a DO cloud firewall that
      limits SSH to your IPs.
- [ ] **Pick an off-box backup option** (phase 1) and set `HEALTHCHECK_URL`.
- [ ] **Old secrets lying around**: the old `db_pass` and `flask_secret` are in
      `chat:latest` (image layers), `/root/chat/.env`, `/root/.env` and the
      `POSTGRES_PASSWORD` of the old container and scripts
      (`/root/deploy_database*.sh`). They are dead after phase 4, but never
      push those images anywhere. Delete the files once the old container is
      gone.
- [ ] **`/root/db.sql`** (2021 dump, mode 644, contains password hashes): move
      it into `/root/backups` or delete it.
- [ ] **Plan the move off Ubuntu 18.04.** Build a new 24.04 droplet, restore
      from a `pg_dump` and the uploads snapshot, then switch DNS. Interim:
      Ubuntu Pro ESM (see the reboot section).
- [ ] After a quiet week: remove the compromised container and its data dir
      ("After phase 4"), and raise HSTS.

## Tests

`deploy/tests/run_local_tests.sh` runs the parts that need no server, docker or
root (130 checks):

- secrets file handling against a port of docker's `--env-file` parser, and
  python-dotenv 0.13.0's quote and override behaviour;
- the generated Dockerfile, with hadolint;
- backup retention and rsync hard-link snapshots;
- the tarball safety checks and the frontend swap;
- the hardened nginx config through `nginx -t`;
- the `daemon.json` merge;
- the `migrate_db.sh` SQL against a real Postgres 16.2: initdb flags and
  pg_hba, the audit, role and DB creation, a non-superuser restore, exact
  counts, what the app role may and may not do (no `COPY … FROM PROGRAM`, no C
  functions, no `postgres` DB), and psycopg2 connecting the way the app does.

Static checks:

```bash
bash -n deploy/*.sh deploy/files/jerboa-backup.sh
shellcheck -S style deploy/*.sh deploy/files/jerboa-backup.sh deploy/tests/run_local_tests.sh
```

Both are clean; `deploy/.shellcheckrc` makes the second one work from any
directory.

Not covered locally:

- `renameat2` itself (Linux only; the fallback is tested);
- anything that needs docker. That is what the smoke test, the rehearsal and
  the automatic rollbacks are for.
