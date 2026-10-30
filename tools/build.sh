#!/usr/bin/env bash
# Builds dist/frontier.love and a Windows version (dist/Frontier-Windows/Frontier.exe + DLLs).
# Works on Linux, macOS and Windows (Git Bash). Needs: zip, curl, unzip.
set -e
cd "$(dirname "$0")/.."
LOVE_VER=11.5
mkdir -p dist
rm -f dist/frontier.love
zip -q -9 dist/frontier.love main.lua conf.lua net.lua profile.lua weapons.lua enemies.lua utility.lua armor.lua
echo "built dist/frontier.love"

# the LÖVE runtime for Windows (downloaded once)
if [ ! -d tools/love-win64 ]; then
    curl -sSL -o tools/love-win64.zip "https://github.com/love2d/love/releases/download/$LOVE_VER/love-$LOVE_VER-win64.zip"
    unzip -q -o tools/love-win64.zip -d tools
    mv "tools/love-$LOVE_VER-win64" tools/love-win64
fi

OUT=dist/Frontier-Windows
rm -rf "$OUT"
mkdir -p "$OUT"
cat tools/love-win64/love.exe dist/frontier.love > "$OUT/Frontier.exe"     # the game fused into love.exe
cp tools/love-win64/*.dll tools/love-win64/license.txt "$OUT/"
(cd dist && rm -f Frontier-Windows.zip && zip -q -r -9 Frontier-Windows.zip Frontier-Windows)
echo "built $OUT/Frontier.exe and dist/Frontier-Windows.zip"
