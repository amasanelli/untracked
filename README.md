# untracked

Git hook that backs up gitignored files (`.env`, secrets, local configs) to an rclone remote. Uploads only when their contents change.

## Setup

```bash
ln -s ~/hub/untracked/untracked.sh <repo>/.git/hooks/post-commit
cp .untracked.conf.sample <repo>/.untracked.conf   # then edit
```

## rclone: Google Drive + crypt

Backups contain secrets, so encrypt them before they reach Drive. Run `rclone config` and create two remotes:

1. **`gdrive`**: `n` (new remote) → name `gdrive` → storage `drive` → leave client id/secret empty → scope `drive.file` (rclone only sees files it created) → defaults for the rest → authorize in the browser when asked.
2. **`gdrive-crypt`**: `n` → name `gdrive-crypt` → storage `crypt` → remote `gdrive:untracked` → filename encryption `standard` → directory name encryption `true` → `y` to type your own password → `y` for a second password (salt).

Store both passwords in a password manager. Without them the backups cannot be decrypted.

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
