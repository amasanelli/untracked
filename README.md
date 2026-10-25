# untracked

Git pre-commit hook that backs up gitignored files (`.env`, secrets, local configs) to an rclone remote. Uploads only when their contents change. If anything goes wrong, the commit is blocked (see [Errors](#errors)).

## Setup

Install [rclone](https://rclone.org/install/):

```bash
sudo dnf install rclone                          # Fedora
sudo apt install rclone                          # Debian/Ubuntu
curl https://rclone.org/install.sh | sudo bash   # any Linux, latest version
```

Clone this repo and hook it into each repo you want backed up:

```bash
git clone https://github.com/amasanelli/untracked.git ~/hub/untracked
ln -s ~/hub/untracked/untracked.sh <repo>/.git/hooks/pre-commit
cp ~/hub/untracked/.untracked.conf.sample <repo>/.untracked.conf   # then edit
```

## rclone: Google Drive + crypt

Backups contain secrets, so they are encrypted before they reach Drive. This uses two rclone remotes, one wrapping the other:

- `gdrive` connects to your Google Drive.
- `gdrive-crypt` sits on top of the `untracked` folder in `gdrive`. Anything written to `gdrive-crypt:` is encrypted (contents and names) and stored there.

The hook writes to `gdrive-crypt`. In Drive you see an `untracked` folder with scrambled file names.

Run `rclone config` and create both remotes. Type the answers below; press Enter to accept the default at any prompt not listed.

**1. `gdrive`**

| Prompt | Answer | Why |
|---|---|---|
| `n/s/q>` or `e/n/d/r/c/s/q>` | `n` | new remote |
| `name>` | `gdrive` | |
| `Storage>` | `drive` | Google Drive |
| `client_id>`, `client_secret>` | empty | use rclone's built-in app |
| `scope>` | `drive.file` | rclone sees only files it created, not the rest of your Drive |
| `Use web browser to automatically authenticate…?` | `y` | a browser opens; log in and allow access |

**2. `gdrive-crypt`**

| Prompt | Answer | Why |
|---|---|---|
| `e/n/d/r/c/s/q>` | `n` | new remote |
| `name>` | `gdrive-crypt` | |
| `Storage>` | `crypt` | encryption layer |
| `remote>` | `gdrive:untracked` | where encrypted files go; the folder is created on first upload |
| `filename_encryption>` | `standard` | file names are encrypted |
| `directory_name_encryption>` | `true` | folder names (your repo names) are encrypted |
| `password` → `y/g>` | `y`, then type it twice | encryption password |
| `password2` → `y/g/n>` | `y`, then type a different one twice | salt, makes the password harder to brute-force |

Store both passwords in a password manager. rclone keeps them in `~/.config/rclone/rclone.conf` only obscured, not encrypted: anyone with that file can decrypt the backups. If you lose that file and the passwords, nobody can, including you.

Check it works:

```bash
rclone mkdir gdrive-crypt:
rclone lsd gdrive-crypt:
```

Then use `dest=gdrive-crypt:` (or `gdrive-crypt:<path>`) in `.untracked.conf`.

## rclone: local or external drive

Create an `alias` remote pointing at a folder on the drive:

```bash
rclone config create usb alias remote=/run/media/$USER/MyDrive/untracked
```

Then use `dest=usb:` in `.untracked.conf`. Backups land in `/run/media/<user>/MyDrive/untracked/<name>/`; missing folders are created.

The drive must be mounted when the hook runs. If it isn't, the upload fails and the commit is blocked, unless the empty mount-point directory is writable: then the backup lands on your main disk instead.

To encrypt these backups too, create a crypt remote like `gdrive-crypt` above, with `remote>` set to `usb:`, and use that remote as `dest`.

## Config

`<repo>/.untracked.conf`:

```
name=myrepo

dest=gdrive-crypt:backups
.env
secrets/

dest=gdrive-crypt:shared
config/local.yml
```

- `dest`: rclone remote, optionally with a path (`gdrive-crypt`, `gdrive-crypt:`, `gdrive-crypt:backups`). The remote must exist in `rclone.conf`. Applies to the paths listed after it, up to the next `dest`. Repeating a `dest` adds more paths to it. A path listed before the first `dest`, or a `dest` with no paths, is an error.
- `name`: optional folder name, used for every dest. Defaults to the origin repo name, else the main worktree's dir name.
- any other line: file or dir relative to the repo root. It must exist and be gitignored; a missing, tracked, absolute or `..` path is an error. Symlinks are followed: the archive holds what they point to.
- lines starting with `#` are comments.

## Worktrees

The hook runs in every worktree of the repo. To back up from a worktree without copying the files, symlink them from the main checkout:

```bash
cd <worktree>
ln -s <main>/.untracked.conf <main>/.env .
```

Every listed path must be there, linked or copied: a missing one blocks the commit.

Git sees a symlink as a file, so a `dir/` pattern doesn't ignore a linked dir, and the hook reports it as not gitignored. Ignore it with `dir` or `/dir` instead, or add that to `<main>/.git/info/exclude`, which applies to all worktrees.

A path linked from several worktrees is uploaded once per change, by whichever worktree commits first. If a worktree has real copies instead of symlinks, its changes are backed up separately from the main checkout's. Both go to the same `<dest>/<name>/` folder; the `<sha>` in the archive name tells you which branch each came from.

## Output

Each dest gets its own archive, a new file `<dest>/<name>/YYYY-MM-DD_HHMMSS_<sha>.tar.gz` holding only its paths, where `<sha>` is the short hash of the commit checked out at backup time, i.e. the parent of the commit being made (`none` on the first commit). Existing files are never overwritten.

List backups, and the files inside one:

```bash
rclone lsl gdrive-crypt:backups/myrepo/
rclone cat gdrive-crypt:backups/myrepo/2026-09-24_220438_4e67d3c.tar.gz | tar -tzv
```

A dest is uploaded only when its files changed since its last backup (hash kept in `.git/untracked-<id>.sha`, shared by all worktrees). To upload every dest anyway, run inside the repo:

```bash
untracked.sh -f
```

## Errors

Any problem prints an `untracked: ERROR:` line: a listed path that is missing, not gitignored or outside the repo, an unknown remote, a file that can't be read, a failed upload, an archive name that already exists. The other dests are still backed up, then the hook exits 1 and git aborts the commit.

Fix the problem and commit again, or skip the backup for one commit:

```bash
git commit --no-verify
```

The remote is needed only when files changed since their last backup, so you can commit offline as long as they didn't.

## Debugging

```bash
untracked.sh -v
```

Run inside a repo to see why nothing was uploaded (no config, no changes).
