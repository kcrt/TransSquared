#!/bin/sh

INPUT="icon_1024x1024.png"
ICONSET="AppIcon.iconset"

mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  sips -z $size $size "$INPUT" --out "$ICONSET/icon_${size}x${size}.png"
  double=$((size * 2))
  sips -z $double $double "$INPUT" --out "$ICONSET/icon_${size}x${size}@2x.png"
done

# .icns に変換
iconutil -c icns "$ICONSET"