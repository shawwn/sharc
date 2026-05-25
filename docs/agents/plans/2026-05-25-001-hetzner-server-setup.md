# Hetzner Server Setup Plan

## Original Request

> I bought a dedicated server from hetzner server auction, then installed
> Ubuntu 24.04 LTS base on it. It's fresh. The SSH key is stored in
> 1password. I'd like you to be able to set up the server from here, and
> document the whole setup process.
>
> Note that the server will need to serve a few different apps. Firstly,
> Lambda News (news.ycombinator.lol, aka LN, aka sharc). Secondly,
> search.ycombinator.lol (algolia search for LN). Thirdly, my blog
> shawwn.net (https://github.com/shawwn/wiki). Fourthly, there should be
> a directory (you can figure out where to put it) where the.shawwn.net
> will serve a directory listing from. It should contain "sda" and "sdb"
> mount points, corresponding to the two 4TB drives.
>
> What's necessary to set you up with ssh access to the server? Should I
> install claude directly on the server, or should you communicate via
> iterm2? What else do you need?
>
> Other requirements: the server should be able to send email,
> specifically to send a reset password link for LN, though I'm not sure
> if it should send directly or proxy through gmail.

## Additional Context (from user)

- DNS is managed via AWS Route 53
- Algolia account: shawnpresser@gmail.com (personal Google account)
- Wiki URL: shawwn.com is lost; now using shawwn.net (wiki repo needs updating)
- Disks: 2x 240GB SSD + 2x 4TB HDD; the 4TB drives should be formatted fresh
- Items and profiles will eventually need Firebase Realtime Database
  (implementing all of https://github.com/hackernews/api); may require
  writing a Firebase client in Arc
- SSH access: via 1Password SSH agent from local Mac (alias `hetzner`)

## Server Details

- **IP**: 88.198.62.84
- **IPv6**: 2a01:4f8:222:642::2
- **OS**: Ubuntu 24.04.3 LTS (kernel 6.8.0-100-generic x86_64)
- **CPU**: Intel i7-7700 @ 3.60GHz (4 cores / 8 threads)
- **RAM**: 64GB
- **SSDs**: 2x 240GB (Samsung MZ7GE240 + MZ7LM240) = sdc, sdd
- **HDDs**: 2x 4TB (Seagate ST4000NM0024) = sda, sdb
- **SSH key**: stored in 1Password

### Initial RAID layout (as delivered)

All 4 disks in RAID arrays:
- md0: RAID1 (32GB swap), 4 disks
- md1: RAID1 (1GB /boot ext3), 4 disks
- md2: RAID6 (381GB / ext4), 4 disks

### Target layout (after rescue reinstall)

- SSDs (sdc+sdd): RAID0 for OS (~480GB usable; swap, /boot, /)
- HDDs (sda, sdb): standalone ext4, mounted at /mnt/sda and /mnt/sdb

RAID0 on SSDs: doubles failure risk, but all code is in git, news
data backs up nightly to both HDDs, wiki rebuilds from GitHub. If an
SSD dies: reinstall OS, restore arc/ data from HDD backup, redeploy.

### HDD directory layout

```
/mnt/sda/
  public/            # served by nginx as the.shawwn.net/sda/
  private/
    backups/         # nightly rsync of SSD data (arc/ dir, etc.)

/mnt/sdb/
  public/            # served by nginx as the.shawwn.net/sdb/
  private/
    backups/         # redundant backup copy
```

Nginx only serves the `public/` subdirectories. The `private/`
directories are outside the web root entirely.

### Backups (rsnapshot)

rsnapshot on both HDDs, backing up the full sharc repo (/opt/sharc),
not just arc/. This captures code, config, and data together so any
snapshot is a complete, deployable state.

Retention: daily (7), weekly (4), monthly (3).

Each snapshot looks like a full copy but uses hardlinks for unchanged
files, so storage cost is only the delta.

```
/mnt/sda/private/backups/
  daily.0/opt/sharc/     # today's snapshot (full repo + arc/)
  daily.1/opt/sharc/     # yesterday
  ...
  weekly.0/opt/sharc/    # this week
  monthly.0/opt/sharc/   # this month

/mnt/sdb/private/backups/
  (same structure, redundant copy)
```

rsnapshot configs:
- /etc/rsnapshot-sda.conf (snapshot_root /mnt/sda/private/backups/)
- /etc/rsnapshot-sdb.conf (snapshot_root /mnt/sdb/private/backups/)

Both configs:
```
retain	daily	7
retain	weekly	4
retain	monthly	3
backup	/opt/sharc/	.
```

Cron (/etc/cron.d/rsnapshot):
```
0  3 * * * root rsnapshot -c /etc/rsnapshot-sda.conf daily
0  3 * * * root rsnapshot -c /etc/rsnapshot-sdb.conf daily
30 3 * * 1 root rsnapshot -c /etc/rsnapshot-sda.conf weekly
30 3 * * 1 root rsnapshot -c /etc/rsnapshot-sdb.conf weekly
0  4 1 * * root rsnapshot -c /etc/rsnapshot-sda.conf monthly
0  4 1 * * root rsnapshot -c /etc/rsnapshot-sdb.conf monthly
```

### Item storage bucketing

At HN scale (~48M items), a flat directory is too slow. Items will be
stored in a two-level bucket scheme:

  story/{id / 1000000}/{(id / 1000) % 1000}/{id}

Example: item 42315678 -> story/42/315/42315678

Each leaf directory holds ~1000 files. Scales to billions.

## Services to Deploy

### 1. Lambda News (news.ycombinator.lol)

The sharc Arc-on-SBCL app. Runs on a port (default 8080), fronted by
nginx with TLS. Source is this repo (`/Users/shawn/ml/sharc7`).

Runtime requirements:
- SBCL (`apt install sbcl`)
- The `arc/` data directory (admins, news items, profiles, votes)
- Runs as `./news.arc` which starts an HTTP server on port 8080

### 2. Search (search.ycombinator.lol)

Algolia-powered search for Lambda News. This will need:
- A small web app or static page that talks to an Algolia index
- Algolia API keys (search-only key for frontend)
- An indexing pipeline that syncs LN stories/comments to Algolia

Starting point: LambdaNews/ln-search is an old fork; rebase onto
the latest HackerNews/hn-search (https://github.com/HackerNews/hn-search).

### 3. Blog (shawwn.net)

A Haskell static site generator (Hakyll/Pandoc). Source at
`github.com/shawwn/wiki`. Currently deploys to S3 (www.shawwn.com).
Domain is now shawwn.net (shawwn.com was lost); wiki repo needs updating.

Everything Haskell-related lives on the HDD (/mnt/sda) to avoid
wasting SSD space (GHC + cabal + build artifacts can be 10-20GB):

```
/mnt/sda/private/
  wiki/                    # git clone of shawwn/wiki
    _site/                 # built site; nginx serves this for shawwn.net
  ghcup/                   # GHC, cabal binaries (GHCUP_INSTALL_BASE_PREFIX)
  cabal/                   # cabal package store (CABAL_DIR)
```

Environment (e.g. in /etc/profile.d/haskell.sh):
```bash
export GHCUP_INSTALL_BASE_PREFIX=/mnt/sda/private
export CABAL_DIR=/mnt/sda/private/cabal
source /mnt/sda/private/ghcup/.ghcup/env
```

Build is CPU-bound (Pandoc), not I/O-bound, so HDD vs SSD makes
little difference. Nginx caches hot files in RAM anyway.

System deps still installed via apt on the SSD (imagemagick, tidy,
mathjax-node-page, GNU parallel, ripgrep); these are small.

Deploy mechanism: webhook or cron that runs
`cd /mnt/sda/private/wiki && git pull && ./build.sh`

### 4. File Server (the.shawwn.net)

A directory listing served by nginx with autoindex. Layout:
```
/srv/the.shawwn.net/
  sda/    -> mount point for first 4TB drive
  sdb/    -> mount point for second 4TB drive
```

## SSH Access for Claude

**Recommended approach: SSH from this Mac via iTerm2.**

Claude Code can run `ssh root@88.198.62.84 <command>` directly from
this Mac. The SSH key is in 1Password, and the 1Password SSH agent is
already configured in `~/.ssh/config`:

```
Host *
  IdentityAgent "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
```

This means Claude can SSH to the server right now, as long as the
1Password SSH key is enabled for this host. No need to install Claude
on the server itself.

**What you need to do:**
1. Make sure the Hetzner SSH key is enabled in 1Password's SSH agent
2. Optionally add an SSH config alias for convenience:
   ```
   Host hetzner
     HostName 88.198.62.84
     User root
   ```
3. Approve SSH commands when Claude runs them (or add ssh to allowed
   commands)

**Alternative: install Claude Code on the server.** This would give
Claude direct local access but adds complexity (API keys on the
server, managing a second Claude instance). The SSH approach is
simpler and keeps everything in one conversation.

## Setup Plan (in order)

### Phase 0: Access and Basics
1. Verify SSH connectivity from this Mac
2. Add SSH config alias for the server
3. Update and upgrade the system (`apt update && apt upgrade`)
4. Set hostname (e.g. `ln1` or `hetzner1`)
5. Set timezone
6. Create a non-root user with sudo (optional but good practice)
7. Harden SSH (disable password auth, change port if desired)
8. Set up UFW firewall (allow 22, 80, 443)

### Phase 1: Disk Restructuring (Hetzner rescue mode)

Since all 4 disks are in RAID arrays, we need to reinstall via rescue:
1. Activate rescue system in Hetzner Robot panel
2. Hardware reset the server
3. SSH into rescue, run `installimage` targeting only SSDs (sdc+sdd)
4. After install, wipe RAID superblocks from HDDs
5. Partition HDDs as single GPT partitions, format ext4
6. Mount at /srv/the.shawwn.net/sda and /srv/the.shawwn.net/sdb
7. Add to /etc/fstab
8. Reboot into new OS

### Phase 2: Core Software
1. Install SBCL, git, build-essential, nginx, certbot
2. Install Node.js (for the wiki webhook server, Algolia indexer)
3. Clone sharc7 repo to `/opt/sharc` or `/srv/news.ycombinator.lol`
4. Clone wiki repo to `/srv/shawwn.net`

### Phase 3: Lambda News
1. Set up the `arc/` data directory with admins
2. Configure `news.arc` site variables (site name, URL, colors)
3. Create a systemd service for `./news.arc` (auto-restart, logging)
4. Test that it runs on port 8080

### Phase 4: Nginx + TLS
1. Install certbot with nginx plugin
2. Configure nginx virtual hosts:
   - `news.ycombinator.lol` -> proxy to localhost:8080
   - `search.ycombinator.lol` -> serve search app or proxy
   - `shawwn.net` / `www.shawwn.net` -> serve /mnt/sda/private/wiki/_site/
   - `the.shawwn.net` -> autoindex (/mnt/sda/public/ and /mnt/sdb/public/)
3. Obtain Let's Encrypt certificates for all domains
4. Set up auto-renewal

**DNS prerequisite**: before TLS works, the domains need A/AAAA
records pointing to 88.198.62.84 / 2a01:4f8:222:642::2. This must
be done in the domain registrar (wherever ycombinator.lol, shawwn.net,
and the.shawwn.net are managed).

### Phase 5: Blog (shawwn.net)
All Haskell tooling and the wiki repo live on /mnt/sda (HDD):
1. Create /etc/profile.d/haskell.sh with GHCUP_INSTALL_BASE_PREFIX
   and CABAL_DIR pointing to /mnt/sda/private/
2. Install ghcup, GHC 9.6.6, cabal to /mnt/sda/private/ghcup/
3. Install system deps via apt (imagemagick, tidy, etc.; small, on SSD)
4. Clone wiki to /mnt/sda/private/wiki/
5. Build the wiki; nginx serves /mnt/sda/private/wiki/_site/
6. Set up deploy webhook or cron (git pull && ./build.sh)
7. Update wiki repo: shawwn.com -> shawwn.net

### Phase 6: Search (search.ycombinator.lol)
1. Rebase LambdaNews/ln-search onto latest HackerNews/hn-search
   (https://github.com/HackerNews/hn-search)
2. Set up Algolia account/credentials (shawnpresser@gmail.com)
3. Build an indexing script that reads from sharc's `arc/news/story/`
   directory and pushes to Algolia
4. Deploy the search frontend
5. Set up periodic re-indexing (cron or triggered on story submission)

### Phase 6b: HN API (https://github.com/hackernews/api)
1. Rebase LambdaNews/API onto latest HackerNews/API
   (https://github.com/HackerNews/API)
2. Eventually back items/profiles with Firebase Realtime Database
3. May require writing a Firebase client in Arc

### Phase 7: Email
For sending password-reset emails from Lambda News. Two options:

**Option A: Gmail SMTP relay (recommended)**
- Use a Gmail account with an App Password
- Configure the app (or a local MTA like msmtp/postfix as relay) to
  send through smtp.gmail.com:587
- Pros: high deliverability, trusted sender reputation, no IP warmup
- Cons: daily send limit (~500/day), depends on Google

**Option B: Direct sending (postfix)**
- Install postfix, configure as internet site
- Set up SPF, DKIM, DMARC DNS records for the sending domain
- Pros: no external dependency, no send limits
- Cons: Hetzner blocks port 25 by default on new servers (need to
  request unblock), IP reputation starts cold, emails may land in spam

**Recommendation**: Gmail relay for now. It's simpler and emails will
actually arrive. The send volume (password resets only) is well within
Gmail's limits. If volume grows, switch to a proper transactional
email service (Postmark, SES, etc.).

The Arc codebase currently has no email-sending code; `resetpw` in
`news.arc` just resets inline when logged in. A "forgot password"
flow will need to be built: generate a token, store it, email a link,
and handle the token-based reset page.

### Phase 8: Monitoring and Maintenance
1. Set up unattended-upgrades for security patches
2. Set up fail2ban
3. Optional: basic monitoring (uptime checks, disk space alerts)
4. Set up log rotation for the Arc app
5. Backups strategy for `arc/` data directory

## Resolved Questions

1. **DNS**: managed via AWS Route 53
2. **Algolia**: personal Google account shawnpresser@gmail.com
3. **Wiki URL**: shawwn.com is lost, now shawwn.net; wiki repo needs updating
4. **4TB drives**: format fresh

## Open Questions

1. **Data migration**: is there existing Lambda News data to migrate,
   or is this a fresh instance?
2. **Non-root user**: should we create a dedicated service user, or
   keep running as root for simplicity during setup?
3. **Email "from" address**: what address should password reset emails
   come from? (e.g. noreply@ycombinator.lol)
4. **Firebase timeline**: when should we start the Firebase integration?
   This is a large project (writing an Arc Firebase client, implementing
   the full HN API). Should it block the initial deployment?
