#!/bin/sh
# Makes the app icon from the logo and writes every size into the asset
# catalog.
#
#     scripts/make-icon.sh [logo.png]
set -eu
cd "$(dirname "$0")/.."
logo="${1:-docs/assets/logo-source.png}"
set_dir="Assets.xcassets/AppIcon.appiconset"
mkdir -p "$set_dir"
master="$(mktemp -d)/icon-1024.png"
swift scripts/IconFromLogo.swift "$logo" "$master"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$master" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$master" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done

cat > "$set_dir/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
printf '{\n  "info" : { "author" : "xcode", "version" : 1 }\n}\n' > Assets.xcassets/Contents.json
# The same artwork for the README and other docs.
sips -z 512 512 "$master" --out docs/assets/idesk-logo.png >/dev/null
echo "Wrote $set_dir and docs/assets/idesk-logo.png"
