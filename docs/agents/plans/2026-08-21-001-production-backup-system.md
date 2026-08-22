# Production Backup System

## Original Request

> what sort of backup system should we put in place for a production deployment
> of this repo? It should be incremental to a separate hard drive, timed (e.g.
> "roll back to X date" is just a matter of copying that folder), and fast (it'd
> be good to run the backup script every few minutes if possible).

Followed by a correction, after a first draft of this plan assumed rsync was the
only tool on the table:

> err, there was a misunderstanding. You can use any tool that can be installed
> onto ubuntu. How do the pros handle this kind of situation? We're not limited
> to rsync.

Status: **proposed, not implemented.** Designed from `docs/server-setup.md`
without connecting to the live box. Phase 3 of that document (deploying Lambda
News) is still TODO, which matters: there is no production data yet, so the
disk layout is free to change right now and never will be again.

Companion note: [2026-08-21-001-apfs-clonefile-backups](../notes/2026-08-21-001-apfs-clonefile-backups.md)
covers the macOS/APFS side (`clonefile`), which does not apply to the Linux
production box.

## Requirements

1. Incremental
2. To a separate hard drive
3. Timed, and "roll back to X date" is just copying that folder
4. Fast enough to run every few minutes

## The principle

**Never let backup cost scale with file count.** There are exactly two ways to
achieve that:

1. **Snapshot below the filesystem** (copy-on-write / block layer): cost is
   O(changed blocks).
2. **Subscribe to changes rather than polling for them** (inotify): cost is
   O(changed files).

rsync does neither. It polls, so it pays for every file every run. Every option
below is one of the two.

## Two measurements that decide the design

### a. Polling costs 61 seconds, minimum

Benchmarked against the real `arc/` tree: **690,153 files, 3.6 GB**. Run on a
Mac (APFS, SSD) with the scraper running, so treat these as relative costs; the
ratios are what matter.

| operation | time |
|---|---|
| bare `find arc -type f` (scan floor) | 22.6s |
| full first `rsync -a --delete` | 215s |
| `rsync --link-dest` snapshot #2 | 282s |
| `rsync --link-dest` snapshot #3 | 311s (rc=24) |
| mirror sync (rsync into one stable dir) | 61s |

Note that `--link-dest` (what rsnapshot does, and what
`/etc/rsnapshot-{sda,sdb}.conf` is configured for) is **slower than a full
copy**, because it must create 690k hardlinks every run. Rotating hardlink
snapshots cannot run every few minutes on this tree at all. Nothing that walks
the tree beats the ~23s scan floor.

### b. The tree is only 192 directories

```
directories in arc/: 192        (186 of them under arc/news, 123 story buckets)
files in arc/:       690,629
```

inotify watches **directories**, not files. Watching the entire tree therefore
costs 192 watches, against an Ubuntu default `fs.inotify.max_user_watches` of
65536 or higher. Event-driven replication is essentially free here, which makes
Stack B below viable without touching the source filesystem.

## The professional options

### Stack A: CoW filesystem at the source + sanoid/syncoid

The industry default for this shape of problem.

```
ZFS dataset for /opt/sharc/arc
   |- sanoid: snapshot every 1-5 min, policy-driven retention   (O(1), instant)
   `- syncoid: zfs send -i  ---->  pool on sdb                  (O(changed blocks))
```

- Snapshots are **atomic and crash-consistent**, which also resolves the torn
  snapshot problem that rsync fundamentally cannot (see below).
- `sanoid` is the standard policy daemon (frequently/hourly/daily/monthly with
  retention counts). `syncoid` is its replication half.
- Restore stays "copy that folder":
  `/opt/sharc/arc/.zfs/snapshot/autosnap_2026-08-21_2145_frequently/`
- btrfs equivalent: `btrbk`, or `snapper` plus `btrfs send/receive`.

Practical notes:

- Hetzner installimage supports btrfs, ext2/3/4, xfs, but **not ZFS root**. This
  does not matter: only the data volume needs to be ZFS, which is a post-install
  `zpool create`.
- Ubuntu 24.04 ships OpenZFS 2.1+ as `zfsutils-linux`; `sanoid` is packaged, but
  the Debian/Ubuntu package ships **no systemd timer for syncoid**, so that unit
  has to be written by hand.
- btrfs is in-kernel and installimage-supported, so it avoids the module
  question entirely. ZFS has the stronger replication tooling. Either is
  defensible; ZFS is the recommendation.

### Stack B: event-driven mirror, without repartitioning

```
lsyncd (inotify, 192 watches) ----> mirror on ZFS/btrfs dataset on sdb
                                       `- sanoid snapshots it every 2 min
```

Sync cost becomes O(changed files) with no change to the source filesystem.
`lsyncd` is packaged in Ubuntu and is used in production for exactly this.

Two requirements: a **periodic full rsync reconcile** (hourly is enough)
because inotify drops events on `IN_Q_OVERFLOW`, and the understanding that
snapshot atomicity lives on the target, so backups are still torn.

### Stack C: restic / borg / kopia

Content-addressed, deduplicating, encrypted, with real retention policies and
integrity verification. `restic mount` and `borg mount` expose a snapshot as a
browsable FUSE tree.

These still walk all 690k files per run (mitigated by an inode/mtime cache), so
they are the **daily offsite layer, not the every-few-minutes layer**.

Hetzner Storage Box speaks BorgBackup, restic, rclone, rsync-over-SSH and SFTP,
which makes it the natural offsite target for this box. The offsite repo should
be **append-only** so a compromised server cannot delete its own backups:
restic via `command="rclone serve restic --stdio <repo>"` in `authorized_keys`,
or borg's `--append-only`. This is the layer that survives ransomware and it is
the one most commonly skipped.

### Stack D: the structural answer (not on the table)

690k tiny files under `arc/news/` is a hand-rolled database on top of the
filesystem. The professional answer to "back up a database every few minutes"
is **WAL plus point-in-time recovery**: a base backup plus continuous archiving
restores to any second and costs nothing per file. That is *why* this problem
feels awkward. Named here for completeness; it would be a rewrite.

## Recommended design

Layered, which is what 3-2-1 means in practice.

| tier | mechanism | interval | protects against |
|---|---|---|---|
| 0 | ZFS snapshots at source (sanoid) | 1-5 min | fat-finger, bad deploy, app bug |
| 1 | `syncoid` to pool on sdb | 5-15 min | SSD failure |
| 2 | restic to Hetzner Storage Box, append-only | daily | fire, theft, ransomware |
| 3 | staleness alerting, quarterly restore drill | n/a | silent failure |

Tier 3 is not optional. The usual way backups fail is quietly.

Two things that are **not** backups and should not be allowed to feel like one:
RAID (see below), and DRBD-style replication, which propagates corruption at
wire speed.

## What this means for the current box

From `docs/server-setup.md`:

```
sdc, sdd  240GB SSD  -> md0 (swap), md1 (/boot), md2 (RAID0, 441GB ext4 /, 3.3GB used)
sda, sdb  4TB HDD    -> standalone ext4, /mnt/sda and /mnt/sdb
```

Proposed changes, in order of value:

1. **`md2` is RAID0.** The OS volume has no redundancy at all today. Rebuilding
   the SSDs as a ZFS mirror gives redundancy, checksums, compression and
   snapshots in a single move. This is worth doing on its own merits.
2. **Put `/opt/sharc/arc` on a ZFS dataset** on that pool, and run sanoid
   against it.
3. **Make one HDD a ZFS pool** to receive `syncoid`. `sda` currently holds the
   wiki, GHC and cabal (~5.4 GB) plus `public/`, so `sdb` is the lower-friction
   choice.
4. **Retire the nightly rsnapshot**, or keep it on the other HDD as an
   independently-implemented second copy. Keeping it is cheap insurance against
   a bug in the new stack.

All of this is far cheaper now than after news is deployed and carrying user
data.

## Implementation notes

**Back up data, not code.** `/opt/sharc` is a git checkout restorable from
GitHub. Only `/opt/sharc/arc/` needs the fast clock. The current rsnapshot
config backs up all of `/opt/sharc/`.

**Exclude `*.tmp`** in any rsync-based leg. `writefile` (`arc.arc:1105`) writes
every file as `<name>.<random16>.tmp` and then renames it (`tmpname`,
`arc.arc:1098-1104`). These vanish mid-sync, which is why benchmark pass #3
returned `rc=24`.

**Treat rsync exit 24 as success**: `[ $rc -eq 0 ] || [ $rc -eq 24 ] || alert`.

**`flock` any polling script.** A 61s job on a 120s timer will eventually
overrun, and overlapping syncs onto one target are ruinous.

**Never `--inplace`.** Default rsync writes a temp file and renames, which is
what keeps snapshots and hardlinks intact.

**Alert on staleness, not on failure**, from outside the backup path: check
that the newest snapshot is younger than N minutes.

## Torn snapshots

Under any rsync- or lsyncd-based scheme (Stacks B and C), snapshots are
**crash-consistent per file but not per set**. Individual files are atomic
(`writefile` is write-temp-then-`mvfile`), but `max-uid`, `uids` and `hpw` can
be captured mid-update relative to each other. In practice that costs a few
minutes of votes or a uid gap, not the site.

Two files are appended in place rather than rewritten, `srv.arc:720` (srv logs)
and `news.arc:3885` (front log). Harmless for the backup: those are source-side
inodes, and rsync never writes in place on the destination.

**Stack A eliminates this entirely.** A ZFS snapshot of the source dataset is a
single atomic point in time across every file at once. This is a real argument
for Stack A over Stack B, independent of speed.

## Off-site

Both HDDs sit in the same chassis on the same PSU, so neither survives losing
the machine. Tier 2 above covers this properly, but note how small the critical
set is if a quick interim measure is wanted:

| file | size |
|---|---|
| `arc/hpw` | ~10 MB |
| `arc/uids` | ~2.8 MB |
| `arc/admins`, `arc/hmac-key`, `arc/cooks` | bytes |

## Open questions

- Willingness to repartition the SSDs now, while there is no production data.
  This gates Stack A vs Stack B and is the only decision that really matters.
- ZFS vs btrfs. ZFS has better replication tooling; btrfs is in-kernel and
  supported by installimage.
- Whether to keep the nightly rsnapshot on the other HDD as a second,
  differently-implemented copy.
- Hetzner Storage Box size and where its keys live.

## Sources

- [Installimage - Hetzner Docs](https://docs.hetzner.com/robot/dedicated-server/operating-systems/installimage/)
- [ZFS snapshot and replication with sanoid and syncoid on Ubuntu](https://www.lguruprasad.in/blog/2025/07/20/my-zfs-snapshot-and-replication-setup-on-ubuntu-ft-sanoid-and-syncoid/)
- [Install and Configure BorgBackup, Hetzner Community](https://community.hetzner.com/tutorials/install-and-configure-borgbackup/)
- [Append-only Restic backups on a Hetzner Storage Box](https://fluix.one/blog/hetzner-restic-append-only/)
- [Hetzner Storage Boxes as backup targets for Restic/Rclone](https://kcore.org/2023/02/01/hetzner-storagebox-backups/)
