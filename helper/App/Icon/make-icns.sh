#!/bin/sh
# Render AppIcon.svg into AppIcon.icns (needs rsvg-convert: brew install librsvg).
# The generated .icns is committed, so building the app does not need this.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
set_dir=$(mktemp -d)/AppIcon.iconset
mkdir -p "$set_dir"
trap 'rm -rf "$(dirname "$set_dir")"' EXIT

for size in 16 32 128 256 512; do
	rsvg-convert -w $size -h $size "$here/AppIcon.svg" -o "$set_dir/icon_${size}x${size}.png"
	rsvg-convert -w $((size * 2)) -h $((size * 2)) "$here/AppIcon.svg" -o "$set_dir/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$set_dir" -o "$here/AppIcon.icns"
echo "wrote $here/AppIcon.icns"
