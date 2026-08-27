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

The server's `arc/` is now its own live datastore. **Do not rsync `arc/`
from a laptop** or you will clobber it. Push code only:

```sh
rsync -Pa --exclude 'arc/' ./ deploy@hetzner:/opt/sharc/
```

`.arc` files hot-reload under `DEV=1`. Changes to `.lisp` files (the
compiler and runtime) need `systemctl restart sharc`.

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
nil, and `test.arc`'s `literals` test died in `arc-id`.

`arc-id` in `arc0.lisp` now masks the trap for the float case only, leaving
integer comparison on the fast path. `anan` is `(no (is x x))`, so it depends
on `is` returning nil here. After the fix both platforms give identical
results and the suite is `968 passed, 0 failed` on each.

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

## Things that are deliberately true

- Port 8080 binds `0.0.0.0`, but ufw only opens 22/80/443, so it is not
  reachable from outside. Binding to `127.0.0.1` would be tidier.
- `ranklink` is commented out in `news.arc`'s subline on purpose.
- The Mac and the server are independent instances with separate datastores.
  They both scrape, so they drift. The server is the live one.
