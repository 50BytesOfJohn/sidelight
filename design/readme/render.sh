#!/bin/sh
# Renders the README banner (design/readme/banner.html) to docs/images/banner.webp at 2x.
# Needs Google Chrome and cwebp (brew install webp). The grain makes a PNG about 2.7 MB; the WebP is about 140 KB.
#   sh design/readme/render.sh
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CHROME=${CHROME:-"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"}
PNG=$(mktemp -t sidelight-banner).png

"$CHROME" --headless=new --disable-gpu --hide-scrollbars --allow-file-access-from-files \
  --force-device-scale-factor=2 --window-size=1280,640 --default-background-color=00000000 \
  --screenshot="$PNG" "file://$ROOT/design/readme/banner.html" 2>/dev/null
cwebp -quiet -q 92 -alpha_q 100 "$PNG" -o "$ROOT/docs/images/banner.webp"
rm -f "$PNG"
echo "Wrote docs/images/banner.webp"
