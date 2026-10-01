# untracked

Git hook that backs up gitignored files (`.env`, secrets, local configs) to an rclone remote. Uploads only when their contents change.

## Setup

```bash
ln -s ~/hub/untracked/untracked.sh <repo>/.git/hooks/post-commit
cp .untracked.conf.sample <repo>/.untracked.conf   # then edit
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

## Config

`<repo>/.untracked.conf`:

```
dest=gdrive-crypt:backups
name=myrepo
.env
secrets/
```

- `dest`: rclone remote, optionally with a path (`gdrive-crypt`, `gdrive-crypt:`, `gdrive-crypt:backups`). The remote must exist in `rclone.conf`.
- `name`: optional folder name. Defaults to the origin repo name, else the repo dir name.
- any other line: file or dir relative to the repo root. Must be gitignored; tracked, absolute and `..` paths are skipped.
- lines starting with `#` are comments.

## Output

Each backup is a new file `<dest>/<name>/YYYY-MM-DD_HHMMSS.tar.gz`. Existing files are never overwritten.

List backups, and the files inside one:

```bash
rclone lsl gdrive-crypt:backups/myrepo/
rclone cat gdrive-crypt:backups/myrepo/2026-09-24_220438.tar.gz | tar -tzv
```

The hash of the last backup is kept in `.git/untracked.sha`. To force a new upload, run inside the repo:

```bash
rm -f "$(git rev-parse --git-path untracked.sha)"
```

## Debugging

```bash
untracked.sh -v
```

Run inside a repo to see why nothing was uploaded (no config, missing files, no changes).
