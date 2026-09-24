#!/bin/bash

set -eo pipefail

[ "$1" = -v ] && VERBOSE=1
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

DEST= NAME= FILES=()
while read -r line || [ -n "$line" ]; do  # also read a last line without trailing newline
  case $line in
    '' | \#*) ;;
    dest=*) DEST=${line#dest=} ;;
    name=*) NAME=${line#name=} ;;
    /* | .. | ../* | */.. | */../*) echo "untracked: skipping path outside repo: $line" >&2 ;;
    *) FILES+=("$line") ;;
  esac
done < "$CONF"

: "${DEST:?dest not set in $CONF}"
[[ $DEST == *:* ]] || DEST+=:  # bare remote name -> remote root
DEST=${DEST%/}
"$RCLONE" listremotes | grep -qxF "${DEST%%:*}:" || { echo "untracked: dest '$DEST' is not on a configured rclone remote" >&2; exit 1; }
# default: repo name from origin URL, else directory name
NAME=${NAME:-$(basename "$("$GIT" remote get-url origin 2>/dev/null || echo "$PWD")" .git)}
NAME=${NAME//\//_}

existing=()
for f in "${FILES[@]}"; do
  if [ ! -e "$f" ]; then log "missing, skipped: $f"
  elif ! "$GIT" check-ignore -q -- "$f"; then echo "untracked: not gitignored, skipped: $f" >&2
  else existing+=("$f"); fi
done
[ ${#existing[@]} -gt 0 ] || { log "nothing to back up from $CONF, skipping"; exit 0; }

# fingerprint of all file contents; skip upload if unchanged
state=$("$GIT" rev-parse --git-path untracked.sha)
hash=$(find "${existing[@]}" -type f -print0 | sort -z | xargs -0r sha256sum | sha256sum | cut -d' ' -f1)
[ "$hash" = "$(cat "$state" 2>/dev/null)" ] && { log "no changes since last backup"; exit 0; }

tmp=$(mktemp --suffix=.tar.gz)
trap 'rm -f "$tmp"' EXIT
tar -czf "$tmp" "${existing[@]}"
[[ $DEST == *: ]] && sep= || sep=/  # "remote:" root takes no slash
target="$DEST$sep$NAME/$(date +%F_%H%M%S).tar.gz"
if "$RCLONE" lsf "$target" >/dev/null 2>&1; then
  echo "untracked: $target already exists, not overwriting" >&2
  exit 1
fi
"$RCLONE" copyto "$tmp" "$target"
echo "$hash" > "$state"
echo "untracked: backed up ${#existing[@]} path(s) to $target"
