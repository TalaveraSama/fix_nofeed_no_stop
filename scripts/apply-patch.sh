#!/usr/bin/env bash
#
# Apply the dvb_net "no feed to stop" fix to a TBS / linux_media source tree
# and (optionally) rebuild + install the media modules.
#
# Usage:
#   ./scripts/apply-patch.sh /path/to/linux_media
#   ./scripts/apply-patch.sh /path/to/media_build/media
#
# The path must be the root of the media source tree, i.e. it contains
#   drivers/media/dvb-core/dvb_net.c
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$HERE/patches/0001-dvb_net-demote-no-feed-to-stop-messages-to-debug.patch"

TREE="${1:-}"
if [[ -z "$TREE" ]]; then
    echo "usage: $0 /path/to/linux_media-or-media_build-tree" >&2
    exit 1
fi

TARGET="$TREE/drivers/media/dvb-core/dvb_net.c"
if [[ ! -f "$TARGET" ]]; then
    echo "error: $TARGET not found. Point me at the media source tree root." >&2
    exit 1
fi

if grep -q 'no feed to stop' "$TARGET" && ! grep -q 'netdev_dbg(dev, "no feed to stop' "$TARGET"; then
    echo ">> Backing up dvb_net.c -> dvb_net.c.orig"
    cp -n "$TARGET" "$TARGET.orig"

    echo ">> Applying patch"
    if command -v git >/dev/null && git -C "$TREE" rev-parse >/dev/null 2>&1; then
        git -C "$TREE" apply --recount --verbose "$PATCH" || patch -p1 -d "$TREE" < "$PATCH"
    else
        patch -p1 -d "$TREE" < "$PATCH"
    fi
else
    echo ">> Patch already applied (or pattern not found); skipping."
fi

echo ">> Verifying"
grep -n 'netdev_dbg(dev, "no feed to stop\|netdev_dbg(dev, "no ts feed to stop' "$TARGET" || true

cat <<'EOF'

Done patching. To rebuild the modules, from the tree root run e.g.:

  # media_build:
  make -j"$(nproc)" && sudo make install

  # in-kernel / dkms tree:
  make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/media/dvb-core modules
  sudo make -C /lib/modules/$(uname -r)/build M=$PWD/drivers/media/dvb-core modules_install

Then reload (or reboot):

  sudo modprobe -r dvb_net dvb_core 2>/dev/null || true
  sudo depmod -a
  # reboot is the safe way when tuners are in use

EOF
