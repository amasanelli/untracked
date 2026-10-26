#!/bin/bash

set -eo pipefail

VERBOSE= FORCE=
while getopts vf opt; do
  case $opt in
    v) VERBOSE=1 ;;
    f) FORCE=1 ;;
    *) echo "usage: untracked.sh [-v] [-f]" >&2; exit 2 ;;
  esac
done
log() { [ -z "$VERBOSE" ] || echo "untracked: $*" >&2; }

# err reports and carries on, so every dest is still tried; die stops now.
# Either way finish exits 1, which blocks the commit
errors=0
err() { echo "untracked: ERROR: $*" >&2; errors=$((errors + 1)); }
die() { err "$@"; finish; }
finish() {
  [ "$errors" = 0 ] || { echo "untracked: $errors error(s), see above. 'git commit --no-verify' skips this hook" >&2; exit 1; }
  exit 0
}
# safety net: a failure not handled below still says what failed
trap 'err "line $LINENO failed: $BASH_COMMAND"; finish' ERR

find_bin() {
  local name="$1" p
  # hooks may run with a minimal PATH
  p=$(command -v "$name" 2>/dev/null) && { echo "$p"; return; }
  for dir in /usr/local/bin /usr/bin /bin "$HOME/bin" "$HOME/.local/bin"; do
    [ -x "$dir/$name" ] && { echo "$dir/$name"; return; }
  done
  die "$name not found"
}

# git sees a symlink as a file and can't look past it: check the first symlinked component
git_path() {
  local p= part parts
  IFS=/ read -ra parts <<< "${1%/}"
  for part in "${parts[@]}"; do
    p+=${p:+/}$part
    [ -L "$p" ] && { echo "$p"; return; }
  done
  echo "$1"
}

RCLONE=$(find_bin rclone) || exit 1
GIT=$(find_bin git) || exit 1
log "using rclone=$RCLONE git=$GIT"

top=$("$GIT" rev-parse --show-toplevel) || die "not inside a git work tree"
cd "$top"
CONF=.untracked.conf
# -L: a broken symlink counts as a config, and fails the next check
[ -e "$CONF" ] || [ -L "$CONF" ] || die "no $CONF in $PWD, nothing backed up (in a worktree: link it from the main checkout)"
[ -f "$CONF" ] && [ -r "$CONF" ] || die "$CONF is not a readable file (broken symlink?)"

# Each dest= starts a block: the paths below it, up to the next dest=. A name= inside a
# block names that block's folder; a name= before the first dest= is the default for every block
DEST= DEFAULT_NAME= FILES=() FILE_BLOCKS=() BLOCK_DESTS=() BLOCK_NAMES=()
while read -r line || [ -n "$line" ]; do  # also read a last line without trailing newline
  line=${line%$'\r'}  # CRLF file: drop the CR
  case $line in
    '' | \#*) ;;
    dest=*)
      DEST=${line#dest=}
      [[ $DEST == *:* ]] || DEST+=:  # bare remote name -> remote root
      DEST=${DEST%/}
      BLOCK_DESTS+=("$DEST"); BLOCK_NAMES+=("") ;;
    name=*)
      if [ -z "$DEST" ]; then DEFAULT_NAME=${line#name=}
      else BLOCK_NAMES[-1]=${line#name=}; fi ;;
    *)
      [[ $line != -* ]] || line=./$line  # or realpath, find and tar take it for an option
      if [ -z "$DEST" ]; then err "$line: listed before any dest= in $CONF, not backed up"
      else FILES+=("$line"); FILE_BLOCKS+=($((${#BLOCK_DESTS[@]} - 1))); fi ;;
  esac
done < "$CONF"
[ ${#BLOCK_DESTS[@]} -gt 0 ] || die "$CONF has no dest= line, nothing backed up"

remotes=$("$RCLONE" listremotes) || die "can't list rclone remotes"
# a block without a name= uses the default: origin's repo name, else the main worktree's dir name
if [ -z "$DEFAULT_NAME" ] && printf '%s\n' "${BLOCK_NAMES[@]}" | grep -qx ''; then
  git_remotes=$("$GIT" remote) || die "can't list git remotes"
  if grep -qxF origin <<< "$git_remotes"; then src=$("$GIT" remote get-url origin) || die "can't read origin's URL"
  else src=$("$GIT" worktree list --porcelain | sed -n '1s/^worktree //p') || die "can't list worktrees"; fi
  DEFAULT_NAME=$(basename "$src" .git)
fi
# Blocks with the same dest and name make one archive: unique, in config order
declare -A archive_of
DESTS=() NAMES=() BLOCK_ARCHIVES=()
for b in "${!BLOCK_DESTS[@]}"; do
  name=${BLOCK_NAMES[b]:-$DEFAULT_NAME}
  name=${name//\//_}
  case $name in '' | . | ..) die "can't use '$name' as the backup folder name, set name= in $CONF" ;; esac
  id=${BLOCK_DESTS[b]}$'\n'$name
  [ -n "${archive_of[$id]}" ] || { archive_of[$id]=${#DESTS[@]}; DESTS+=("${BLOCK_DESTS[b]}"); NAMES+=("$name"); }
  BLOCK_ARCHIVES+=("${archive_of[$id]}")
done
# HEAD is the parent of the commit being made; rc 1: no commits yet
rc=0; COMMIT=$("$GIT" rev-parse -q --verify --short HEAD) || rc=$?
case $rc in 0) ;; 1) COMMIT=none ;; *) die "can't read HEAD" ;; esac
common=$("$GIT" rev-parse --git-common-dir) || die "can't find the git dir"

# The archive being uploaded, under a .partial name until it's complete: deleted if the upload
# fails or is interrupted, so no half-written archive is left
uploading=
discard() { [ -z "$uploading" ] || "$RCLONE" deletefile "$uploading" >/dev/null 2>&1 || true; uploading=; }
trap 'discard; err "interrupted, no archive left"; finish' INT TERM
for a in "${!DESTS[@]}"; do
  DEST=${DESTS[a]} NAME=${NAMES[a]}
  [[ $DEST == *: ]] && sep= || sep=/  # "remote:" root takes no slash
  where=$DEST$sep$NAME
  grep -qxF "${DEST%%:*}:" <<< "$remotes" ||
    { err "dest '$DEST' is not on a configured rclone remote, nothing backed up to $where"; continue; }
  existing=() listed=0
  for i in "${!FILES[@]}"; do
    [ "${BLOCK_ARCHIVES[FILE_BLOCKS[i]]}" = "$a" ] || continue
    listed=$((listed + 1))
    f=${FILES[i]}
    case $f in /* | .. | ../* | */.. | */../*) err "$f: outside the repo, not backed up to $where"; continue ;; esac
    [ -e "$f" ] || { err "$f: missing, not backed up to $where"; continue; }
    rc=0; "$GIT" check-ignore -q -- "$(git_path "$f")" || rc=$?
    case $rc in
      0) existing+=("$f") ;;
      1) err "$f: not gitignored (or tracked by git), not backed up to $where" ;;
      *) err "$f: git check-ignore failed, not backed up to $where" ;;
    esac
  done
  [ "$listed" -gt 0 ] || { err "dest '$DEST' (name '$NAME') has no paths listed under it in $CONF"; continue; }
  [ ${#existing[@]} -gt 0 ] || { log "nothing to back up to $where, skipping"; continue; }

  # Skip the upload if the hash of all file contents (symlinks followed) is unchanged.
  # The last hash is kept in the common git dir, keyed by dest, name and real paths, so
  # a path linked into several worktrees is uploaded once per change. C locale: same
  # order, so same key and hash, whatever locale the hook runs under
  real=$(realpath "${existing[@]}" | LC_ALL=C sort) || { err "can't resolve the paths for $where, not backed up"; continue; }
  key=$(printf '%s\n' "$DEST" "$NAME" "$real" | sha256sum | cut -c1-16)
  state="$common/untracked-$key.sha"
  hash=$(find -L "${existing[@]}" -type f -print0 | LC_ALL=C sort -z | xargs -0r sha256sum | sha256sum | cut -d' ' -f1) ||
    { err "can't read the files for $where, not backed up"; continue; }
  prev=  # no state file: never backed up
  [ ! -e "$state" ] || prev=$(cat "$state") || err "can't read $state, uploading $where anyway"
  [ -z "$FORCE" ] && [ "$hash" = "$prev" ] && { log "no changes for $where since last backup"; continue; }

  target="$where/$(date +%F_%H%M%S)_$COMMIT.tar.gz"
  rc=0; lsf_err=$("$RCLONE" lsf "$target" 2>&1 >/dev/null) || rc=$?  # keep only stderr
  case $rc in
    0) err "$target already exists, not overwriting"; continue ;;
    3 | 4) ;;  # rclone: directory / file not found, free to upload
    *) echo "$lsf_err" >&2; err "can't check whether $target exists, not backed up"; continue ;;
  esac
  # --inplace: rclone writes the .partial file itself, not a temp file of its own beside it
  uploading=$target.partial
  if ! tar -chzf - "${existing[@]}" | "$RCLONE" rcat --inplace "$uploading"; then
    discard; err "upload to $target failed, no archive left"; continue
  fi
  if ! "$RCLONE" moveto "$uploading" "$target"; then
    discard; err "can't rename $target.partial to $target, no archive left"; continue
  fi
  uploading=
  echo "untracked: backed up ${#existing[@]} path(s) to $target"
  echo "$hash" > "$state" || err "can't save $state, $where is uploaded again next time"
done
finish
