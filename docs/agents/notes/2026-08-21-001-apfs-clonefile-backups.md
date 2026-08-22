---
name: APFS clonefile backups
description: How `cp -c` / clonefile(2) makes near-free copy-on-write backups of a tree on APFS, measured costs and timings on this repo's `arc/`, an rsync-equivalent `clonesync` wrapper, and the footguns (du lies, gcp truncates existing destinations, snapshots pin space).
type: reference
---

# APFS clones as cheap backups (2026-08-21)

Written up after [2026-08-21-001-phantom-comments-and-fetched-rename](../handoff/2026-08-21-001-phantom-comments-and-fetched-rename.md),
where the data migrations under `arc/` were done against "a full APFS clone
backup taken first". This note explains what that actually was, why it cost
nothing, and how to reproduce the idiom.

All numbers below were measured on this machine (macOS 14.4, APFS on
`/dev/disk3s5`), not quoted from documentation.

## 1. What a clone is

`cp -c` uses the `clonefile(2)` syscall instead of a read/write loop. APFS
creates a second directory entry pointing at **the same physical blocks**,
marked copy-on-write. No file data is duplicated.

Copying `log.txt` (54 MB) three ways:

| method | disk cost |
|---|---|
| `cp -c` (clonefile) | 16 KB |
| plain `cp` | 55,220 KB |
| `rsync -a` | 55,232 KB |
| `ditto` | 55,156 KB |

The 16 KB is metadata only: a new inode plus its extent references. Note that
plain `cp` does **not** clone by default on this macOS version; `-c` is
required. Neither does `ditto`.

## 2. Copy-on-write is per block

This is what makes a clone a real backup rather than a fragile alias. Free
space on the volume, watched through a sequence of mutations to a 54 MB clone:

```
free before:          1068833552 KB
after cp -c:          1068833548 KB   (cost 4 KB)
after poking 4 KB:    1068833532 KB   (cost 16 KB)
after full rewrite:   1068777720 KB   (cost ~55 MB)
```

Writing into a cloned file allocates fresh blocks for **only the blocks
touched** and repoints that file's extent map at them. The other file keeps
pointing at the originals. Neither copy can see the other's edits, so the
backup is genuinely immutable from the live tree's point of view, and you pay
only for divergence. That is why the `arc/` backup cost nothing up front and
only cost the blocks of the 483 json records that were later rewritten.

Restoring is symmetric and equally cheap:

```sh
rm -rf arc && cp -Rpc arc-backup arc
```

Deleting the live tree drops its references; the blocks survive because the
backup still holds them. Cloning back is another metadata-only operation.

## 3. Backing up a whole tree

### The muscle-memory equivalent of `rsync -Pa src/ dst/`

```sh
cp -Rpc some/path/ dest/path/
```

The trailing-slash rule is the same as rsync's: `src/` copies the *contents*
into `dst/`. It is re-runnable; overwriting an existing file still clones,
because BSD `cp` unlinks the destination first and then calls `clonefile`.

Metadata fidelity is better than `rsync -a`, because `clonefile(2)` copies the
file's attributes as part of the clone:

| | mode | file mtime | dir mtime | symlinks | xattrs |
|---|---|---|---|---|---|
| `cp -Rc` | yes | yes | **no** | yes | yes |
| `cp -Rpc` | yes | yes | yes | yes | yes |
| `rsync -a` | yes | yes | yes | yes | **no** |

`-p` is only needed to fix up *directory* timestamps. Apple's bundled rsync is
2.6.9 (2006) and silently drops xattrs unless given `-E`.

What `cp -Rpc` lacks: no `--delete`, no `-P` progress, and it re-walks and
re-clones every file on every run.

### Full `rsync -a --delete` semantics: `clonesync`

GNU coreutils' `cp` (installed here as `gcp`) does support APFS cloning. The
invocation that actually works, wrapped with a delete pass:

```sh
clonesync() {                       # clonesync SRC DST
  local src=${1%/} dst=${2%/}
  [ -d "$src" ] || { echo "clonesync: no such dir: $src" >&2; return 1; }
  mkdir -p "$dst" || return 1
  gcp -a --reflink=always --remove-destination -u "$src/." "$dst/" || return 1
  ( cd "$dst" && find . -mindepth 1 -depth ) | while IFS= read -r p; do
      p=${p#./}
      [ -e "$src/$p" ] || [ -L "$src/$p" ] || rm -rf "$dst/$p"
  done
}
```

Note `src/.` rather than `src/`: GNU's trailing-slash handling differs from
rsync's. `-u` makes it incremental. Verified against a fixture with changed
files, new files and a deleted subtree; `diff -r src dst` comes back
identical.

**Two `gcp` traps, both reproduced:**

1. `--reflink=always` **fails on an existing destination file and leaves it
   truncated** (`failed to clone: Operation not supported`, and the 60 MB
   destination came back short). `clonefile` requires the destination not to
   exist, and GNU cp does not unlink first the way BSD cp does.
   `--remove-destination` fixes it.
2. `--reflink=auto` does not fix it; it silently falls back to a real byte
   copy. You get a correct file and a full-price copy, which defeats the
   point.

### Measured comparison

`arc/scrape`, 51,083 files, 573 MB:

| | first run | incremental | disk cost |
|---|---|---|---|
| `rsync -a --delete` | 11.5s | 0.43s | 640 MB |
| `cp -Rpc` | 12.9s | 14.4s | 20 MB |
| `clonesync` | 5.5s | 1.0s | 23 MB |

The ~20 MB is pure metadata (51k inodes and extent maps). Cloning is
metadata-bound, not data-bound, which is why a full `arc/` clone (688,882
files, 3.0 GB as of this writing) takes roughly 2.5 minutes: the 3 GB is free,
the 689k inodes are not.

## 4. Snapshots, the other mechanism

Same underlying CoW machinery, different tool:

```sh
tmutil localsnapshot          # snapshot the whole volume
tmutil listlocalsnapshots /
mount_apfs -s <name> / /mnt   # mount read-only to pull files out
```

Differences that matter:

- **Granularity.** Snapshots are volume-wide and read-only. Clones are per
  file or per directory, and writable.
- **Visibility.** A clone is a directory you can name `arc-backup-aug21` and
  see in `ls`. A snapshot is invisible until mounted.
- **Lifetime.** Local snapshots are thinned by Time Machine (typically after
  24 hours, or under space pressure). A clone lives until you `rm` it.

For "I am about to rewrite 483 data files", the clone is the right tool.

## 5. Footguns

1. **`du` lies.** It reports logical size and knows nothing about sharing.
   `du -sh arc-backup` will say 3 GB; deleting it may free ~0 bytes, because
   the live tree still references most of those blocks. A block is freed when
   the last reference goes away. Finder's Get Info lies the same way. The only
   reliable measurement is a `df` delta before and after.
2. **A clone is not an off-disk backup.** Same volume, same physical drive. It
   protects against *you*, not against hardware. Git and an external drive
   still matter.
3. **Sharing is silently lost by ordinary tools.** `rsync`, `ditto`, `tar`,
   `git checkout` and plain `cp` all write real bytes. Clone a tree and then
   rsync over it and you have paid full price.
4. **`cp -c` fails loudly** across volumes or on non-APFS filesystems rather
   than silently falling back, which is good: you will know.
5. **Snapshots pin deleted blocks.** If deleting a large file frees no space,
   an old snapshot is usually holding it.
6. **The scraper writes while you clone.** Cloning `arc/` while news is
   running produces `No such file or directory` for `*.json.raw` and `*.tmp`
   files that vanish mid-run; rsync hits the same thing and exits 24. Exclude
   the temp patterns, and do not treat a nonzero exit as failure without
   checking which files it named.
7. **`gcp -u` skips when the destination is newer**, whereas rsync copies
   whenever size or mtime *differ* in either direction. Fine for a backup
   directory you never hand-edit; drop `-u` otherwise.

## 6. Relevance to this repo

The `../sharc22-experiment-backup-*` and `../sharc*-backup*` directories are
exactly this pattern applied at repo level. Sixty-odd of them are nearly free
**provided they were made with `cp -Rpc`**; a plain `cp -R` or `rsync -a` copy
costs full price. The pre-migration backup convention in the handoffs assumes
the clone form.
