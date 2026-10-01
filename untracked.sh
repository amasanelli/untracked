#!/bin/bash

set -eo pipefail

VERBOSE= FORCE=
while [ -n "$1" ]; do
  case "$1" in
    -v) VERBOSE=1 ;;
    -f) FORCE=1 ;;
    *) break ;;
  esac
  shift
done
log() { [ -z "$VERBOSE" ] || echo "untracked: $*" >&2; }

find_bin() {
  local name="$1" p
  # hooks/cron may run with a minimal PATH
  p=$(command -v "$name" 2>/dev/null) && { echo "$p"; return; }
  for dir in /usr/local/bin /usr/bin /bin "$HOME/bin" "$HOME/.local/bin"; do
    [ -x "$dir/$name" ] && { echo "$dir/$name"; return; }
  done
  echo "ERROR: $name not found" >&2
  exit 1
}

RCLONE=$(find_bin rclone)
GIT=$(find_bin git)
log "using rclone=$RCLONE git=$GIT"

cd "$("$GIT" rev-parse --show-toplevel)"
CONF=.untracked.conf
[ -f "$CONF" ] || { log "no $CONF in $PWD, skipping"; exit 0; }

# each dest= line applies to the paths below it, until the next dest=
DEST= NAME= FILES=() FILE_DESTS=()
while read -r line || [ -n "$line" ]; do  # also read a last line without trailing newline
  case $line in
    '' | \#*) ;;
    dest=*)
      DEST=${line#dest=}
      [[ $DEST == *:* ]] || DEST+=:  # bare remote name -> remote root
      DEST=${DEST%/} ;;
    name=*) NAME=${line#name=} ;;
    /* | .. | ../* | */.. | */../*) echo "untracked: skipping path outside repo: $line" >&2 ;;
    *)
      [ -n "$DEST" ] || { echo "untracked: '$line' is listed before any dest= in $CONF" >&2; exit 1; }
      FILES+=("$line"); FILE_DESTS+=("$DEST") ;;
  esac
done < "$CONF"
[ ${#FILES[@]} -gt 0 ] || { log "nothing to back up from $CONF, skipping"; exit 0; }

mapfile -t DESTS < <(printf '%s\n' "${FILE_DESTS[@]}" | awk '!seen[$0]++')  # unique, in config order
remotes=$("$RCLONE" listremotes)
for DEST in "${DESTS[@]}"; do
  grep -qxF "${DEST%%:*}:" <<< "$remotes" || { echo "untracked: dest '$DEST' is not on a configured rclone remote" >&2; exit 1; }
done
# default: repo name from origin URL, else directory name
NAME=${NAME:-$(basename "$("$GIT" remote get-url origin 2>/dev/null || echo "$PWD")" .git)}
NAME=${NAME//\//_}

tmp=$(mktemp --suffix=.tar.gz)
trap 'rm -f "$tmp"' EXIT
status=0
for DEST in "${DESTS[@]}"; do
  existing=()
  for i in "${!FILES[@]}"; do
    [ "${FILE_DESTS[i]}" = "$DEST" ] || continue
    f=${FILES[i]}
    if [ ! -e "$f" ]; then log "missing, skipped: $f"
    elif ! "$GIT" check-ignore -q -- "$f"; then echo "untracked: not gitignored, skipped: $f" >&2
    else existing+=("$f"); fi
  done
  [ ${#existing[@]} -gt 0 ] || { log "nothing to back up to $DEST, skipping"; continue; }

  # fingerprint of all file contents, one per dest; skip upload if unchanged
  state=$("$GIT" rev-parse --git-path "untracked-$(printf %s "$DEST" | sha256sum | cut -c1-16).sha")
  hash=$(find "${existing[@]}" -type f -print0 | sort -z | xargs -0r sha256sum | sha256sum | cut -d' ' -f1)
  [ -z "$FORCE" ] && [ "$hash" = "$(cat "$state" 2>/dev/null)" ] && { log "no changes for $DEST since last backup"; continue; }

  tar -czf "$tmp" "${existing[@]}"
  [[ $DEST == *: ]] && sep= || sep=/  # "remote:" root takes no slash
  target="$DEST$sep$NAME/$(date +%F_%H%M%S).tar.gz"
  if "$RCLONE" lsf "$target" >/dev/null 2>&1; then
    echo "untracked: $target already exists, not overwriting" >&2
    status=1; continue
  fi
  "$RCLONE" copyto "$tmp" "$target" || { status=1; continue; }
  echo "$hash" > "$state"
  echo "untracked: backed up ${#existing[@]} path(s) to $target"
done
exit $status
