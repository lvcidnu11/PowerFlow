#!/bin/zsh
# Regenerates all icon assets from make_icon.swift:
#   icon_1024.png / icon_light_1024.png   framed dark + light previews (README)
#   AppIcon.icon/                         Icon Composer icon, light + dark appearance (macOS 26+)
#   AppIcon.icns                          fallback used when actool isn't available (dark)
set -e
cd "$(dirname "$0")"
swift make_icon.swift icon_1024.png
swift make_icon.swift icon_light_1024.png --light

# Icon Composer bundle: macOS applies the mask/shadow, so art is full-bleed
rm -rf AppIcon.icon Assets.xcassets && mkdir -p AppIcon.icon/Assets
swift make_icon.swift AppIcon.icon/Assets/light.png --bleed --light
swift make_icon.swift AppIcon.icon/Assets/dark.png --bleed
cat > AppIcon.icon/icon.json <<'EOF'
{
  "groups" : [
    {
      "layers" : [
        {
          "image-name-specializations" : [
            { "value" : "light.png" },
            { "appearance" : "dark", "value" : "dark.png" }
          ],
          "name" : "PowerFlow"
        }
      ]
    }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
EOF

# .icns fallback
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon_1024.png --out AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "wrote icon/AppIcon.icon and icon/AppIcon.icns"
