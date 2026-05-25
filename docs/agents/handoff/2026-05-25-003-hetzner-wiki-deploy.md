---
name: hetzner-wiki-deploy
description: Continued Hetzner server setup (from 002). Installed Haskell toolchain, built wiki, set up wiki-private overlay, deploy user, nginx + TLS for all domains, Route 53 DNS.
type: project
---

# Handoff: Hetzner server wiki deploy and hardening (2026-05-25)

Continuation of `2026-05-25-002-hetzner-server-setup`. That session
completed disk restructuring and base system setup. This session
deployed the wiki, set up the private overlay, and created a
non-root service user.

## What was accomplished

### Wiki build pipeline on HDD

Installed the full Haskell toolchain onto `/mnt/sda/private/` (the
HDD) to keep the SSD free:

- GHC 9.6.6 + cabal 3.14 via ghcup (2.9GB in `/mnt/sda/private/.ghcup/`)
- Cabal package store (2.2GB in `/mnt/sda/private/cabal/`)
- Wiki repo cloned to `/mnt/sda/private/wiki/`
- System deps installed via apt: imagemagick, tidy, parallel, ripgrep,
  nodejs, npm, zlib1g-dev, libffi-dev, libgmp-dev

Initial build completed successfully. Built site at
`/mnt/sda/private/wiki/_site/` (44MB).

**TMPDIR fix**: LinkMetadata.hs uses `renameFile` from `/tmp` to
`static/metadata/auto.hs`. Since `/tmp` is on the SSD and the wiki
is on the HDD, this fails with "Invalid cross-device link". Fixed by
setting `TMPDIR=/mnt/sda/private/wiki/tmp` in the environment profile
(`/etc/profile.d/haskell.sh`).

### wiki-private overlay

- Created private GitHub repo `shawwn/wiki-private`
- Initialized with test content from the overlay session (test-private.page,
  docs/private/test.txt)
- Cloned to `/mnt/sda/private/wiki-private/` (sibling of wiki)
- Overlay tested on server: `./overlay.sh link` correctly symlinks
  private content into the wiki

### GitHub SSH deploy keys

Server has two SSH keypairs for GitHub access (deploy keys, read-only):

| Key file | SSH host alias | GitHub repo |
|---|---|---|
| `~/.ssh/id_ed25519` | `github-wiki-private` | shawwn/wiki-private |
| `~/.ssh/id_ed25519_wiki` | `github-wiki` | shawwn/wiki |

SSH config (`~/.ssh/config`) maps host aliases to the correct keys.
Both repos now use SSH remotes (not HTTPS).

### Wiki branch rename (master -> main)

Renamed the wiki repo's default branch from `master` to `main` via
`gh api repos/shawwn/wiki/branches/master/rename`. Updated local
clone, server clone, and rebuild script.

### Auto-rebuild cron

`/usr/local/bin/wiki-rebuild.sh` runs every 5 minutes via cron.
It fetches both wiki and wiki-private repos; if either has new
commits, it pulls, runs `overlay.sh link`, and rebuilds.

### Service user (`deploy`)

Created a non-root user `deploy` (uid 1000) to run all services.
Transferred ownership of all app directories. SSH deploy keys copied.
Wiki rebuild cron runs as `deploy`. rsnapshot backups still run as
root.

### ImageMagick remote URL fix (committed to wiki repo)

`staticImg` in Main.hs was running ImageMagick's `identify` on remote
image URLs (e.g. `https://i.imgur.com/...`), which fails because
`identify` can't fetch HTTP. This caused `error` to be called, Hakyll
caught the exception, and wrote 0-byte output files for memorybox.page
and swarm.page. Fixed by adding http/https prefix checks to the
`vector` guard so remote URLs are skipped (same as SVGs and data URIs).

Wiki commit: `a8a5556`

### wiki-private GitHub repo created

Created `github.com/shawwn/wiki-private` (private). Initialized from
the test content produced by the overlay session (test-private.page,
docs/private/test.txt). Committed and pushed.

### Nginx + TLS + DNS

Set up nginx vhosts and Let's Encrypt TLS for all domains:

| Domain | Behavior |
|---|---|
| `https://shawwn.net` | serves wiki from /mnt/sda/private/wiki/_site/ |
| `https://www.shawwn.net` | 301 -> shawwn.net |
| `https://the.shawwn.net` | autoindex of /srv/the.shawwn.net/ (sda/, sdb/ symlinks) |
| `https://news.ycombinator.lol` | proxy to localhost:8080 (502 until Lambda News deployed) |
| `https://ycombinator.lol` | 301 -> news.ycombinator.lol |
| `https://www.ycombinator.lol` | 301 -> news.ycombinator.lol |
| all HTTP | 301 -> HTTPS |

DNS: installed AWS CLI, updated Route 53 ycombinator.lol zone with
A + AAAA records for ycombinator.lol, www.ycombinator.lol, and
news.ycombinator.lol (all pointing to 88.198.62.84 / 2a01:4f8:222:642::2).
`docs.ycombinator.lol` left untouched (delegated to Vercel via NS records).

shawwn.net DNS is managed at Namecheap (not Route 53) and was already
pointing to the server.

Certbot auto-renewal is enabled for all certs. Certs expire 2026-08-23.

nginx `default_type text/html` added for the wiki vhost because Hakyll
generates extensionless HTML files (e.g. `_site/index` not `_site/index.html`).

### Plan documents updated

- `docs/server-setup.md`: updated with all executed commands, marked
  Phase 5 (blog) as DONE, added service user section, wiki-private
  overlay, and deploy user setup
- `docs/agents/plans/2026-05-25-001-hetzner-server-setup.md`: updated
  with wiki-private overlay details

## Key decisions

- **TMPDIR on HDD**: required because Haskell's `renameFile` (used by
  LinkMetadata.hs) can't rename across filesystems. Set globally in
  `/etc/profile.d/haskell.sh`.

- **Cron polling over webhooks**: 5-minute cron is simpler than a
  webhook server (no extra port, no GitHub config, no failure modes).
  Acceptable latency for a personal blog.

- **Two deploy keys, not one account key**: GitHub doesn't allow the
  same deploy key on two repos. Generated a second keypair and used
  SSH host aliases in `~/.ssh/config`.

- **deploy user over root**: all app processes (wiki build, Lambda News
  when deployed, etc.) run as `deploy`. Root only for system admin and
  backups.

- **Pushed overlay.sh from local**: the overlay commit existed locally
  but hadn't been pushed to GitHub. Pushed it so the server could pull.

- **default_type text/html in nginx**: Hakyll outputs extensionless
  HTML files (e.g. `_site/index`). Without this, nginx serves them as
  `application/octet-stream`.

- **the.shawwn.net uses symlinks**: `/srv/the.shawwn.net/sda` and `sdb`
  are symlinks to `/mnt/sda/public` and `/mnt/sdb/public`. This keeps
  the nginx root clean and decoupled from the mount paths.

- **Single cert per domain group**: one cert covers ycombinator.lol +
  www + news; another covers shawwn.net + www; the.shawwn.net has its
  own. This matches the nginx vhost structure.

## Important context for future sessions

### Server state summary

| Component | Status | Path |
|---|---|---|
| OS + base packages | DONE | Ubuntu 24.04, hostname `ln1` |
| Disk layout | DONE | SSDs RAID0 /, HDDs at /mnt/sda /mnt/sdb |
| rsnapshot backups | DONE | /etc/rsnapshot-{sda,sdb}.conf |
| Wiki build | DONE | /mnt/sda/private/wiki/_site/ |
| Wiki auto-rebuild | DONE | /etc/cron.d/wiki-rebuild (as deploy) |
| wiki-private overlay | DONE | /mnt/sda/private/wiki-private/ |
| Service user | DONE | deploy (uid 1000) |
| Nginx + TLS | DONE | all domains serving with Let's Encrypt |
| DNS (Route 53) | DONE | ycombinator.lol A/AAAA records updated |
| Lambda News | TODO | /opt/sharc/ (dir exists, not cloned) |
| Search (Algolia) | TODO | |
| HN API / Firebase | TODO | |
| Email (password reset) | TODO | |

### File locations on server

```
/mnt/sda/private/
  .ghcup/              # GHC 9.6.6, cabal 3.14
  cabal/               # cabal package store
  wiki/                # shawwn/wiki clone
    _site/             # built site (nginx will serve this)
    tmp/               # TMPDIR for builds
  wiki-private/        # shawwn/wiki-private clone

/opt/sharc/            # (empty, owned by deploy, for Lambda News)

/home/deploy/.ssh/
  config               # SSH host aliases for GitHub
  id_ed25519           # deploy key for wiki-private
  id_ed25519_wiki      # deploy key for wiki

/usr/local/bin/wiki-rebuild.sh    # auto-rebuild script
/etc/cron.d/wiki-rebuild          # 5-min cron (runs as deploy)
/etc/cron.d/rsnapshot             # backup cron (runs as root)
/etc/profile.d/haskell.sh         # GHCUP/CABAL/TMPDIR env vars
/etc/rsnapshot-sda.conf           # backup config for sda
/etc/rsnapshot-sdb.conf           # backup config for sdb

/etc/nginx/sites-available/
  shawwn.net             # wiki site
  the.shawwn.net         # directory listing (HDD public dirs)
  ycombinator.lol        # Lambda News proxy + redirects

/etc/letsencrypt/live/
  shawwn.net/            # cert for shawwn.net + www.shawwn.net
  the.shawwn.net/        # cert for the.shawwn.net
  ycombinator.lol/       # cert for ycombinator.lol + www + news

/srv/the.shawwn.net/
  sda -> /mnt/sda/public   # symlink
  sdb -> /mnt/sdb/public   # symlink
```

### Known issues

- Some non-fatal `[ERROR]` lines from LinkMetadata.hs when it fails to
  fetch external URLs for link popup metadata. These don't block the
  build after the ImageMagick fix, but metadata for those links will
  be missing from popups.

### AWS CLI

Installed on local Mac (`brew install awscli`), configured with root
access key for Route 53 management. Credentials in `~/.aws/credentials`.
Route 53 hosted zone for ycombinator.lol: `Z09137391LCSEX2EUZFAM`.

### Next steps

Phase 3 (Lambda News deployment) is the main remaining task. The
nginx proxy to localhost:8080 is already configured and returns 502
until the app is running.
