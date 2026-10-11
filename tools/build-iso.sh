#!/usr/bin/env bash
set -euo pipefail

FLAVOR="${1:-gnome}"

case "$FLAVOR" in
  gnome|kde|hyprland)
    ;;
  *)
    echo "Usage: $0 {gnome|kde|hyprland}"
    exit 1
    ;;
esac

BUILD_DIR="build/puskasos-${FLAVOR}"
IMAGE="ghcr.io/zalnars/puskasos:${FLAVOR}"
ISO_NAME="puskasos-${FLAVOR}-$(date +%Y.%m.%d.%H.%M).iso"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

pushd "$BUILD_DIR" >/dev/null

sudo bluebuild generate-iso \
  -V kinoite \
  --platform linux/amd64/v2 \
  --iso-name "$ISO_NAME" \
  --secure-boot-url "https://puskasos.014321.xyz/download/public_key.der" \
  --enrollment-password="puskasos" \
  image "$IMAGE"

WEBSEED="https://puskasos.014321.xyz/download/puskasos-${FLAVOR}/"
TORRENT="${ISO_NAME%.iso}.torrent"

mktorrent \
  -a "udp://tracker-udp.gbitt.info:80/announce" \
  -a "udp://tracker.torrent.eu.org:451/announce" \
  -w "$WEBSEED" \
  -o "$TORRENT" \
  "$ISO_NAME"

# not needed as blue-build already creates it
#md5sum "$ISO_NAME" > "$ISO_NAME-CHECKSUM"

touch latest.html latest-checksum.html latest-torrent.html
cat > latest.html << EOF
<!doctype html><html><head><meta charset="UTF-8"><meta http-equiv=refresh content="0;url=https://puskasos.014321.xyz/download/puskasos-$FLAVOR/$ISO_NAME"/></head></html>
EOF
cat > latest-checksum.html << EOF
<!doctype html><html><head><meta charset="UTF-8"><meta http-equiv=refresh content="0;url=https://puskasos.014321.xyz/download/puskasos-$FLAVOR/$ISO_NAME-CHECKSUM"/></head></html>
EOF
cat > latest-torrent.html << EOF
<!doctype html><html><head><meta charset="UTF-8"><meta http-equiv=refresh content="0;url=https://puskasos.014321.xyz/download/puskasos-$FLAVOR/$TORRENT"/></head></html>
EOF

echo "Created:"
echo "  $BUILD_DIR/$ISO_NAME"
echo "  $BUILD_DIR/$TORRENT"
echo "  $BUILD_DIR/$ISO_NAME-CHECKSUM"
echo "  $BUILD_DIR/latest.html"
echo "  $BUILD_DIR/latest-checksum.html"
echo "  $BUILD_DIR/latest-torrent.html"

popd >/dev/null