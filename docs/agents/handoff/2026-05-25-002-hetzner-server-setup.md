---
name: hetzner-server-setup
description: Provisioned a Hetzner dedicated server (88.198.62.84) with Ubuntu 24.04 on RAID0 SSDs, standalone 4TB HDDs, and base infrastructure for hosting Lambda News, shawwn.net, search, and file serving.
type: project
---

# Handoff: Hetzner server setup (2026-05-25)

Bought a Hetzner server auction box and set it up from scratch via SSH
from the local Mac (using 1Password SSH agent). No commits to the
sharc repo; all work was server-side plus two local plan documents.

## What was accomplished

### Disk restructuring (via Hetzner rescue mode)

The server arrived with all 4 disks (2x 240GB SSD + 2x 4TB HDD) in
RAID arrays together. We reinstalled via `installimage` in rescue mode
to separate them:

- **SSDs (sdc+sdd)**: RAID0, ~441GB, running the OS
- **HDD sda**: 3.6TB standalone ext4, mounted at `/mnt/sda`
- **HDD sdb**: 3.6TB standalone ext4, mounted at `/mnt/sdb`

Each HDD has `public/` (will be served by nginx for the.shawwn.net)
and `private/backups/` (rsnapshot snapshots, not web-accessible).

### System setup

- Ubuntu 24.04.3 LTS, hostname `ln1`, timezone UTC
- All packages updated
- Base packages installed: nginx, sbcl, certbot, git, build-essential,
  ufw, fail2ban, unattended-upgrades, rsnapshot
- UFW firewall: ports 22, 80, 443 only
- SSH hardened: key-only auth (password auth disabled)
- rsnapshot configured on both HDDs backing up `/opt/sharc/` with
  daily (7), weekly (4), monthly (3) retention

### Plan documents created

- `docs/agents/plans/2026-05-25-001-hetzner-server-setup.md`: full
  plan with all phases, architecture decisions, and open questions
- `docs/server-setup.md`: command-by-command setup log (reproducible)

## Key decisions

- **RAID0 on SSDs** rather than RAID1: doubles failure risk but gives
  ~441GB instead of ~220GB. Acceptable because code is in git, news
  data backs up nightly to both HDDs via rsnapshot, wiki rebuilds from
  GitHub. Recovery from SSD failure = reinstall + restore from HDD backup.

- **Haskell tooling on HDD**: GHC, cabal, the wiki repo, and all build
  artifacts live on `/mnt/sda/private/` to avoid consuming SSD space
  (can be 10-20GB). Build is CPU-bound so HDD vs SSD barely matters.

- **Item storage bucketing**: at HN scale (~48M items), flat directories
  are too slow. Plan is two-level bucketing:
  `story/{id/1000000}/{(id/1000)%1000}/{id}` giving ~1000 files per
  leaf directory.

- **Gmail SMTP relay** for email (password reset links) rather than
  direct sending. Hetzner blocks port 25 on new servers, and volume is
  low enough that Gmail's limits are fine.

- **Repo name is `sharc.git`** (not `sharc7.git`).

## Important context for future sessions

### Server access

```
ssh hetzner    # alias in ~/.ssh/config -> root@88.198.62.84
```

Uses 1Password SSH agent. The ED25519 key is registered in both the
Hetzner Robot panel (for rescue mode) and the server's authorized_keys.

### What's deployed where

| Path | What |
|---|---|
| `/opt/sharc/` | (not yet cloned) sharc repo; will run Lambda News |
| `/mnt/sda/public/` | (empty) will be served as the.shawwn.net/sda/ |
| `/mnt/sdb/public/` | (empty) will be served as the.shawwn.net/sdb/ |
| `/mnt/sda/private/backups/` | rsnapshot daily/weekly/monthly of /opt/sharc/ |
| `/mnt/sdb/private/backups/` | redundant rsnapshot copy |
| `/mnt/sda/private/wiki/` | (not yet cloned) wiki repo for shawwn.net |
| `/mnt/sda/private/ghcup/` | (not yet installed) GHC/cabal toolchain |

### DNS (not yet configured)

Managed in AWS Route 53. Needs A/AAAA records for:
- `news.ycombinator.lol` -> 88.198.62.84
- `search.ycombinator.lol` -> 88.198.62.84
- `shawwn.net` / `www.shawwn.net` -> 88.198.62.84
- `the.shawwn.net` -> 88.198.62.84

### GitHub orgs

- `LambdaNews` org (owned by shawnpresser@gmail.com) has old forks:
  - `LambdaNews/ln-search`: rebase onto `HackerNews/hn-search`
  - `LambdaNews/API`: rebase onto `HackerNews/API`

### Remaining phases (see plan doc for details)

- **Phase 3**: Clone sharc, deploy Lambda News with systemd service
- **Phase 4**: Nginx vhosts + Let's Encrypt TLS (blocked on DNS)
- **Phase 5**: Wiki/blog build pipeline on HDD (shawwn.com -> shawwn.net migration)
- **Phase 6**: Algolia search (shawnpresser@gmail.com account)
- **Phase 6b**: HN API + Firebase Realtime Database (long-term)
- **Phase 7**: Email sending (Gmail relay for password reset)

### Known considerations

- The wiki repo (`github.com/shawwn/wiki`) still references
  `shawwn.com` in `env.sh` and elsewhere; needs updating to `shawwn.net`
- The Arc codebase has no "forgot password" email flow yet; `resetpw`
  only works when already logged in. A token-based email reset flow
  needs to be built.
- Firebase integration is a large future project (writing a Firebase
  client in Arc to implement the full HN API).
