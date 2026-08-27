# Deploying sharc to hetzner

How the live instance at <https://news.ycombinator.lol> is set up and run.
Written 2026-08-26.

## The short version

```sh
ssh deploy@hetzner
tmux a            # NOT `tmux -a`; tmux has no -a option
```

That drops you straight into the running Arc repl, with News serving on
port 8080 behind nginx.

To detach again without killing anything: `Ctrl-b d`.

## What runs where

| Thing | Location | Notes |
|-------|----------|-------|
| Code + data | `/opt/sharc` | owned by `deploy`, on the SSD (`/` is a RAID0 of the two Samsung SSDs) |
| App process | tmux session `sharc`, window `repl` | started by `sharc.service` |
| SBCL | `/usr/local/bin/sbcl` (2.6.3) | Ubuntu's `/usr/bin/sbcl` is 2.2.9 and too old, see below |
| `lwrap` | `/opt/scrap/lwrap` | from <https://github.com/shawwn/scrap>, on `PATH` via `/etc/profile.d/scrap.sh` |
| Reverse proxy | nginx `news.ycombinator.lol` -> `127.0.0.1:8080` | TLS via Let's Encrypt |
| Backups | restic, hourly | repo at `/mnt/sdb/private/restic` |

The two 3.6T spinning disks are `/mnt/sda` and `/mnt/sdb`. The SSD RAID is
`/`, which is why `/opt/sharc` satisfies "on the SSD".

## The app

`sharc.service` starts a detached tmux session and runs the app inside it,
so the repl survives logout and comes back on reboot:

```
ExecStart=/usr/bin/tmux new-session -d -s sharc -n repl \
    "DEV=1 PORT=8080 lwrap ./sharc scrape.arc"
```

`scrape.arc` does `(load "news.arc")` at line 25, so this boots News *and*
the scraper. `DEV=1` enables autoreload of `.arc` files.

`loginctl enable-linger deploy` is set so systemd does not reap the tmux
server when no one is logged in.

```sh
systemctl status sharc         # is it up
systemctl restart sharc        # bounce it (drops the repl session)
sudo -u deploy tmux ls         # list sessions
```

Note `remain-on-exit on` is set on the session, so if the repl dies the pane
stays with its scrollback intact instead of vanishing.

### Updating the code

`/opt/sharc` is a git checkout tracking `origin`
(<https://github.com/shawwn/sharc>), so updates come from a pull, not a
copy. **Do not rsync onto it**: that dirties tracked files, and the next
pull refuses with "your local changes would be overwritten by merge".

```sh
git push                                  # from the laptop
sudo -u deploy git -C /opt/sharc pull     # on the server
```

Then pick the code up from the repl, without restarting anything:

```arc
arc> (reload)
```

**`.lisp` changes do not need a restart.** `DEV=1` autoreloads `.arc`
files on their own, and `(reload)` calls `(reload-runtime)`, which
recompiles `arc0.lisp` and `arc1.lisp` and loads them into the live image
in about 290ms. See `docs/agents/handoff/2026-08-21-004-reloadable-lisp-runtime.md`.

The one case that does need a restart is when a **struct changed shape**.
`reload-runtime` refuses rather than leaving live instances stranded
under the old layout:

```
reload-runtime: refusing, struct shape changed:
  live instances cannot be migrated; restart the image.
```

It returns nil having changed nothing, so a refusal is safe: fix it or
`systemctl restart sharc`. `(reload-runtime t)` reloads anyway and
abandons any instance made under the old layout.

Run git as `deploy`, not as root. The tree is owned by `deploy`, and root
git refuses with `detected dubious ownership in repository at
'/opt/sharc'`.

The server's `arc/` is its own live datastore, and `.gitignore` carries
`/arc/`, so a pull will not touch it. Never copy `arc/` from a laptop.

## SBCL

Ubuntu 24.04 ships SBCL 2.2.9, which is too old: `arc0.lisp` references
`sb-unix:clock-gettime`, which was not external in `SB-UNIX` back then, so
the boot dies with

```
The symbol "CLOCK-GETTIME" is not external in the SB-UNIX package.
```

Fix was to install the upstream 2.6.3 binary into `/usr/local`, matching the
dev machine, and leave the distro package alone:

```sh
curl -sSLO https://downloads.sourceforge.net/project/sbcl/sbcl/2.6.3/sbcl-2.6.3-x86-64-linux-binary.tar.bz2
tar xf sbcl-2.6.3-x86-64-linux-binary.tar.bz2
cd sbcl-2.6.3-x86-64-linux && INSTALL_ROOT=/usr/local sh install.sh
```

### The NaN trap

x86-64 Linux enables the `:invalid` floating point trap by default; macOS on
ARM does not. So `(= nan nan)` *signalled* on the server instead of returning
nil, and `test.arc`'s `literals` test died in the identity primitive.

`arc-exactly` in `arc0.lisp` (once `arc-id`, then `arc-same`) now masks the
trap for the float case only, leaving integer comparison on the fast path.
`anan` is `(no (is x x))`, so it depends on `is` returning nil here. After
the fix both platforms give identical results and the suite passes on each.

## TLS / certbot

All three certs (`shawwn.net`, `the.shawwn.net`, `ycombinator.lol`) had
expired on 2026-08-23 because renewal was failing, and it was failing in a
way worth understanding:

1. certbot writes the challenge under `/var/www/html/.well-known/acme-challenge/`
2. Let's Encrypt fetches `http://news.ycombinator.lol/.well-known/...`
3. the `:80` server block did a blanket `return 301 https://...`
4. the `:443` block proxies everything to `127.0.0.1:8080`
5. nothing was listening there, so the challenge got a **502**

In other words, cert renewal depended on the app being up. Two fixes:

**`/etc/nginx/snippets/acme-challenge.conf`**, included in every `:80` block
*before* any redirect, with the redirect moved into `location /`:

```nginx
location ^~ /.well-known/acme-challenge/ {
    root /var/www/html;
    default_type "text/plain";
    try_files $uri =404;
}
```

**`/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh`**, which reloads
nginx after a successful renewal. The authenticator is `webroot`, so there is
no installer to do it, and without the hook nginx keeps serving the old cert.

Verify the challenge path is reachable without involving the app:

```sh
echo ok > /var/www/html/.well-known/acme-challenge/probe
curl http://news.ycombinator.lol/.well-known/acme-challenge/probe   # expect: ok
rm /var/www/html/.well-known/acme-challenge/probe
certbot renew --dry-run
```

## Backups

restic replaced rsnapshot for `/opt/sharc` on 2026-08-26. The old rsnapshot
cron is commented out in `/etc/cron.d/rsnapshot`, with the original preserved
at `/root/rsnapshot.cron.bak`; the `-sda`/`-sdb` confs are untouched, so
re-enabling is just restoring that file.

- Repo: `/mnt/sdb/private/restic` (one of the big spinning disks)
- **No password.** Deliberate: local disk, no key management wanted. Every
  restic call therefore needs `--insecure-no-password`, which the wrappers
  pass for you.
- Schedule: `restic-backup.timer`, hourly, `Persistent=true` so a missed run
  catches up after downtime.
- Retention: 24 hourly, 14 daily, 8 weekly, 12 monthly.

```sh
restic-backup /opt/sharc        # back up now
restic-snapshots                # list snapshots
restic-run check                # verify integrity
restic-run restore latest --target /tmp/restore --path /opt/sharc
restic-run mount /mnt/browse    # browse snapshots as a filesystem
```

Config lives in `/etc/restic/env`. Note `RESTIC_CACHE_DIR` is pinned there:
systemd starts services with `HOME` unset, and restic then fails with
`unable to locate cache directory` and exits 1. That bit us; do not remove it.

Ubuntu's restic is 0.16.4, which has no `--insecure-no-password` and has
`self-update` stripped. `/usr/local/bin/restic` is the upstream 0.19.1 binary
and shadows it.

### Caveat: backups are not quiesced

The app is writing to `arc/` while restic runs, so a snapshot is a
crash-consistent view, not an atomic one. Fine for this workload; worth
knowing before trusting a restore of a half-written `hpw`.

## Unattended upgrades and needrestart

Ubuntu's `apt-daily-upgrade` timer runs unattended-upgrades, which calls
`needrestart`, which restarts any service holding a deleted library. The
running sbcl maps `libssl.so.3` and `libcrypto.so.3`, so an openssl
upgrade makes `sharc.service` a candidate -- and because the tmux server
**is** that unit's main process, restarting it destroys the repl session
and the app's in-memory state.

That is exactly what happened on 2026-08-27:

```
06:25:04  unattended-upgrades: libssl3t64, openssl 3.0.13-0ubuntu3.12 -> .15
06:25:05  systemd: Reexecuting requested (unit apt-daily-upgrade.service)
06:25:06  tmux: server exited unexpectedly
06:25:06  sharc.service: Main process exited, code=dumped, status=6/ABRT
06:25:06  sharc.service: Started
```

tmux was a bystander; it does not link libssl at all.

`/etc/needrestart/conf.d/sharc.conf` now excludes the unit:

```perl
$nrconf{override_rc}{qr(^sharc)} = 0;
```

**This carries an obligation.** With the override in place the running
image keeps the *old* libssl mapped until someone restarts it by hand,
and this app makes outbound HTTPS connections to scrape HN. After any
openssl or libssl upgrade:

```sh
systemctl restart sharc
```

This is the one place a real restart is required rather than `(reload)`.
`reload-runtime` recompiles lisp *source* into the live image; it cannot
re-map a shared library the process already has open. Only a new process
picks up the new libssl.

The proper fix is not a setting. tmux attaches to a tmux server, not to
an arbitrary process, so the app cannot be daemonised separately and
then attached to -- decoupling would need the image to listen for repl
connections on a socket, the swank model, which this runtime does not
have. There is a browser repl in the meantime: `prompt.arc` defines an
admin-gated `/repl` op, which reaches the live image without a terminal.

### Pending kernel upgrade

`needrestart` also reports that the running kernel is `6.8.0-117-generic`
against an expected `6.8.0-138-generic`. Unattended-upgrades will not
reboot on its own unless configured to, so this is waiting on a
deliberate reboot. That one is a real outage, not just an app restart.

## Things that are deliberately true

- Port 8080 binds `0.0.0.0`, but ufw only opens 22/80/443, so it is not
  reachable from outside. Binding to `127.0.0.1` would be tidier.
- The Mac and the server are independent instances with separate datastores.
  They both scrape, so they drift. The server is the live one.
