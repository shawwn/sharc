# Hetzner Server Setup Log

Server: 88.198.62.84 (ssh alias: `hetzner`)
OS: Ubuntu 24.04.3 LTS
CPU: Intel i7-7700 @ 3.60GHz (8 threads)
RAM: 64GB
Disks: 2x 4TB HDD (ST4000NM0024) + 2x 240GB SSD (Samsung MZ7GE240 / MZ7LM240)

## Initial Disk Layout (as delivered by Hetzner)

All 4 disks were in RAID arrays:
- md0: RAID1 (32GB) = swap, all 4 disks
- md1: RAID1 (1GB) = /boot (ext3), all 4 disks
- md2: RAID6 (381GB) = / (ext4), all 4 disks

Only 3.3GB was actually used on the root filesystem.

## Phase 1: Disk Restructuring (via Hetzner rescue mode) [DONE]

### Goal

- SSDs (sdc, sdd) run the OS in RAID0 (~441GB usable)
- HDDs (sda, sdb) are standalone 4TB ext4 drives
- HDDs mounted at /mnt/sda and /mnt/sdb
- Each HDD has public/ (served by nginx) and private/ (backups, not served)

### installimage (run from rescue system)

```bash
# Config written to /tmp/installconfig
cat > /tmp/installconfig << 'EOF'
DRIVE1 /dev/sdc
DRIVE2 /dev/sdd

SWRAID 1
SWRAIDLEVEL 0

BOOTLOADER grub

HOSTNAME ln1

PART swap swap 4G
PART /boot ext3 1024M
PART /     ext4 all

IMAGE /root/.oldroot/nfs/images/Ubuntu-noble-latest-amd64-base.tar.gz
EOF

/root/.oldroot/nfs/install/installimage -a -c /tmp/installconfig
```

### HDD setup (run from rescue system, after installimage)

```bash
# Stop old RAID arrays
mdadm --stop /dev/md0
mdadm --stop /dev/md1
mdadm --stop /dev/md2

# Wipe RAID superblocks from the HDDs
mdadm --zero-superblock /dev/sda1 /dev/sda2 /dev/sda3
mdadm --zero-superblock /dev/sdb1 /dev/sdb2 /dev/sdb3

# Create single partition on each HDD
parted -s /dev/sda mklabel gpt
parted -s /dev/sda mkpart primary ext4 0% 100%
parted -s /dev/sdb mklabel gpt
parted -s /dev/sdb mkpart primary ext4 0% 100%

# Format
mkfs.ext4 -L sda-storage /dev/sda1
mkfs.ext4 -L sdb-storage /dev/sdb1

# Reassemble new RAID arrays to access new OS
mdadm --assemble /dev/md0 /dev/sdc1 /dev/sdd1
mdadm --assemble /dev/md1 /dev/sdc2 /dev/sdd2
mdadm --assemble /dev/md2 /dev/sdc3 /dev/sdd3

# Mount new root and add HDD fstab entries
mkdir -p /mnt/newroot
mount /dev/md2 /mnt/newroot
echo '' >> /mnt/newroot/etc/fstab
echo '# 4TB HDDs' >> /mnt/newroot/etc/fstab
echo 'LABEL=sda-storage /mnt/sda ext4 defaults,noatime 0 2' >> /mnt/newroot/etc/fstab
echo 'LABEL=sdb-storage /mnt/sdb ext4 defaults,noatime 0 2' >> /mnt/newroot/etc/fstab
mkdir -p /mnt/newroot/mnt/sda /mnt/newroot/mnt/sdb

umount /mnt/newroot
reboot
```

### Final disk layout (after reboot)

```
sda       3.6T disk
└─sda1    3.6T part  ext4  /mnt/sda   (label: sda-storage)
sdb       3.6T disk
└─sdb1    3.6T part  ext4  /mnt/sdb   (label: sdb-storage)
sdc     223.6G disk
├─sdc1      2G part  -> md0 (RAID0 swap, 4GB)
├─sdc2      1G part  -> md1 (RAID1 /boot ext3, 1GB)
└─sdc3  220.6G part  -> md2 (RAID0 / ext4, 441GB)
sdd     223.6G disk
├─sdd1      2G part  -> md0
├─sdd2      1G part  -> md1
└─sdd3  220.6G part  -> md2
```

### HDD directory structure (created after reboot)

```bash
mkdir -p /mnt/sda/public /mnt/sda/private/backups
mkdir -p /mnt/sdb/public /mnt/sdb/private/backups
```

## Phase 2: System Setup [DONE]

```bash
# Timezone (already UTC from installimage)
ssh hetzner "timedatectl set-timezone UTC"

# Update system
ssh hetzner "apt update && DEBIAN_FRONTEND=noninteractive apt upgrade -y"

# Install base packages
ssh hetzner "DEBIAN_FRONTEND=noninteractive apt install -y \
  git build-essential curl wget \
  nginx certbot python3-certbot-nginx \
  sbcl \
  ufw fail2ban \
  unattended-upgrades apt-listchanges \
  rsnapshot"

# Configure firewall
ssh hetzner "ufw default deny incoming && \
  ufw default allow outgoing && \
  ufw allow 22/tcp && \
  ufw allow 80/tcp && \
  ufw allow 443/tcp && \
  ufw --force enable"

# Harden SSH (installimage already set PermitRootLogin without-password)
ssh hetzner "echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config"
ssh hetzner "systemctl restart ssh"
```

### rsnapshot setup [DONE]

```bash
# Config for sda (tab-separated; rsnapshot is picky about this)
cat > /etc/rsnapshot-sda.conf << 'EOF'
config_version	1.2
snapshot_root	/mnt/sda/private/backups/
cmd_cp	/bin/cp
cmd_rm	/bin/rm
cmd_rsync	/usr/bin/rsync
cmd_logger	/usr/bin/logger
retain	daily	7
retain	weekly	4
retain	monthly	3
verbose	2
loglevel	3
logfile	/var/log/rsnapshot-sda.log
backup	/opt/sharc/	.
EOF

# Config for sdb (identical except snapshot_root and logfile)
sed 's|/mnt/sda/|/mnt/sdb/|;s|rsnapshot-sda|rsnapshot-sdb|' \
  /etc/rsnapshot-sda.conf > /etc/rsnapshot-sdb.conf

# Cron
cat > /etc/cron.d/rsnapshot << 'EOF'
0  3 * * * root rsnapshot -c /etc/rsnapshot-sda.conf daily
0  3 * * * root rsnapshot -c /etc/rsnapshot-sdb.conf daily
30 3 * * 1 root rsnapshot -c /etc/rsnapshot-sda.conf weekly
30 3 * * 1 root rsnapshot -c /etc/rsnapshot-sdb.conf weekly
0  4 1 * * root rsnapshot -c /etc/rsnapshot-sda.conf monthly
0  4 1 * * root rsnapshot -c /etc/rsnapshot-sdb.conf monthly
EOF
```

## Service User [DONE]

All services run as `deploy` (uid 1000), not root. Root is only for
system administration and rsnapshot backups.

```bash
useradd -m -s /bin/bash -d /home/deploy deploy

# Transfer ownership of app directories
chown -R deploy:deploy /mnt/sda/private/wiki /mnt/sda/private/wiki-private \
  /mnt/sda/private/.ghcup /mnt/sda/private/cabal \
  /mnt/sda/public /mnt/sdb/public /opt/sharc

# Copy GitHub deploy keys to deploy user
mkdir -p /home/deploy/.ssh
cp /root/.ssh/id_ed25519* /root/.ssh/id_ed25519_wiki* /root/.ssh/config /home/deploy/.ssh/
chown -R deploy:deploy /home/deploy/.ssh
chmod 700 /home/deploy/.ssh
chmod 600 /home/deploy/.ssh/id_ed25519 /home/deploy/.ssh/id_ed25519_wiki /home/deploy/.ssh/config
ssh-keyscan github.com >> /home/deploy/.ssh/known_hosts
```

Cron jobs run as deploy (wiki-rebuild) or root (rsnapshot backups).

## Phase 3: Deploy Lambda News [TODO]

```bash
# Clone sharc repo
ssh hetzner "git clone https://github.com/shawwn/sharc.git /opt/sharc"

# Set up data directory
ssh hetzner "mkdir -p /opt/sharc/arc && echo 'shawn' > /opt/sharc/arc/admins"

# Create systemd service (see phase 3 section in plan doc)
# Test: ssh hetzner "cd /opt/sharc && ./news.arc"
```

## Phase 4: Nginx + TLS + DNS [DONE]

### DNS (Route 53)

ycombinator.lol hosted zone: Z09137391LCSEX2EUZFAM

```bash
# Updated via AWS CLI (aws route53 change-resource-record-sets)
# A + AAAA records for ycombinator.lol, www, news -> 88.198.62.84 / 2a01:4f8:222:642::2
# docs.ycombinator.lol left untouched (delegated to Vercel via NS records)
```

shawwn.net DNS is at Namecheap (not Route 53), already pointed to server.

### TLS certificates (Let's Encrypt)

```bash
certbot certonly --webroot -w /var/www/html \
  -d shawwn.net -d www.shawwn.net --non-interactive --agree-tos --email shawnpresser@gmail.com

certbot certonly --webroot -w /var/www/html \
  -d the.shawwn.net --non-interactive --agree-tos --email shawnpresser@gmail.com

certbot certonly --webroot -w /var/www/html \
  -d ycombinator.lol -d www.ycombinator.lol -d news.ycombinator.lol \
  --non-interactive --agree-tos --email shawnpresser@gmail.com
```

Auto-renewal enabled by certbot. Certs expire 2026-08-23.

### Nginx vhosts

```bash
# /etc/nginx/sites-available/shawwn.net
# - http -> https redirect
# - www.shawwn.net -> shawwn.net redirect
# - serves /mnt/sda/private/wiki/_site/ with default_type text/html
#   (Hakyll outputs extensionless HTML files)

# /etc/nginx/sites-available/the.shawwn.net
# - http -> https redirect
# - autoindex of /srv/the.shawwn.net/ (sda/ and sdb/ symlinks)

# /etc/nginx/sites-available/ycombinator.lol
# - http -> https redirect
# - ycombinator.lol and www -> news.ycombinator.lol redirect
# - news.ycombinator.lol -> proxy to localhost:8080
```

### the.shawwn.net directory structure

```bash
mkdir -p /srv/the.shawwn.net
ln -sf /mnt/sda/public /srv/the.shawwn.net/sda
ln -sf /mnt/sdb/public /srv/the.shawwn.net/sdb
```

## Phase 5: Blog (shawwn.net) [DONE]

All Haskell tooling lives on HDD (/mnt/sda) to save SSD space.
Total HDD usage: ~5.4GB (GHC 2.9GB, cabal 2.2GB, wiki 390MB).

### Haskell environment

```bash
# /etc/profile.d/haskell.sh
export GHCUP_INSTALL_BASE_PREFIX=/mnt/sda/private
export CABAL_DIR=/mnt/sda/private/cabal
export TMPDIR=/mnt/sda/private/wiki/tmp
[ -f /mnt/sda/private/.ghcup/env ] && source /mnt/sda/private/.ghcup/env
```

TMPDIR must be on the HDD (same filesystem as the wiki) because
LinkMetadata.hs uses renameFile from /tmp to static/metadata/auto.hs,
which fails across filesystems.

### Install steps (already executed)

```bash
# Install ghcup non-interactively
export GHCUP_INSTALL_BASE_PREFIX=/mnt/sda/private
export CABAL_DIR=/mnt/sda/private/cabal
curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | \
  BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
  BOOTSTRAP_HASKELL_GHC_VERSION=9.6.6 \
  BOOTSTRAP_HASKELL_INSTALL_NO_STACK=1 sh

# System deps
apt install -y imagemagick tidy parallel ripgrep nodejs npm \
  zlib1g-dev libffi-dev libgmp-dev

# Clone and build
git clone https://github.com/shawwn/wiki.git /mnt/sda/private/wiki
cd /mnt/sda/private/wiki
mkdir -p tmp
export TMPDIR=/mnt/sda/private/wiki/tmp
source /mnt/sda/private/.ghcup/env
cabal update
cabal build wiki
cabal run wiki -- clean
cabal run wiki -- build
```

### wiki-private overlay

Private content lives in a sibling repo (github.com/shawwn/wiki-private,
private). overlay.sh symlinks private files into the wiki at build time.

```bash
# Clone wiki-private next to wiki
git clone git@github-wiki-private:shawwn/wiki-private.git /mnt/sda/private/wiki-private
```

Server uses two deploy keys (one per repo) with SSH host aliases:
- github-wiki -> ~/.ssh/id_ed25519_wiki (wiki repo)
- github-wiki-private -> ~/.ssh/id_ed25519 (wiki-private repo)

### Auto-rebuild cron (every 5 minutes)

Checks both repos for changes; rebuilds with overlay if either updated.

```bash
# /usr/local/bin/wiki-rebuild.sh
#!/bin/bash
set -e
export GHCUP_INSTALL_BASE_PREFIX=/mnt/sda/private
export CABAL_DIR=/mnt/sda/private/cabal
export TMPDIR=/mnt/sda/private/wiki/tmp
source /mnt/sda/private/.ghcup/env

WIKI=/mnt/sda/private/wiki
PRIVATE=/mnt/sda/private/wiki-private
CHANGED=0

cd $WIKI
git fetch origin
if ! git diff --quiet HEAD origin/main; then
  git pull origin main
  CHANGED=1
fi

cd $PRIVATE
git fetch origin
if ! git diff --quiet HEAD origin/main; then
  git pull origin main
  CHANGED=1
fi

if [ $CHANGED -eq 1 ]; then
  cd $WIKI
  ./overlay.sh link
  cabal run wiki -- build 2>&1 | logger -t wiki-build
  echo "$(date): wiki rebuilt" >> /var/log/wiki-build.log
fi
```

```bash
# /etc/cron.d/wiki-rebuild
*/5 * * * * root /usr/local/bin/wiki-rebuild.sh 2>&1 | logger -t wiki-rebuild
```

## Phase 6: Search (search.ycombinator.lol) [TODO]

Algolia account: shawnpresser@gmail.com
Rebase LambdaNews/ln-search onto latest HackerNews/hn-search.

## Phase 6b: HN API [TODO]

Rebase LambdaNews/API onto latest HackerNews/API.
Eventually back items/profiles with Firebase Realtime Database.
May require writing a Firebase client in Arc.

## Phase 7: Email [TODO]

For password reset emails. Gmail relay recommended (low volume).
