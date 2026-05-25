---
name: hetzner-wiki-deploy
description: Continued Hetzner server setup (from 002). Installed Haskell toolchain on HDD, built the wiki, set up wiki-private overlay, created deploy user, configured auto-rebuild cron.
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

### Plan documents updated

- `docs/server-setup.md`: updated with all executed commands, marked
  Phase 5 (blog) as DONE, added service user section
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
| Lambda News | TODO | /opt/sharc/ (dir exists, not cloned) |
| Nginx + TLS | TODO | blocked on DNS (Route 53) |
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
```

### Known issues

- Wiki build has non-fatal errors: failed imgur image downloads for
  link metadata (LinkMetadata.hs tries to curl external URLs). These
  produce `[ERROR]` lines but don't block the build.
- `swarm.page` throws an exception during persist ("An exception was
  thrown when persisting the compiler result"). Non-fatal.

### Next steps

Phase 3 (Lambda News) and Phase 4 (Nginx + TLS) are next. DNS
records in Route 53 need to be created before TLS can work.
