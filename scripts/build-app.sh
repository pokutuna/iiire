#!/bin/bash
# Koe をビルドし、speech コマンドと一緒に Koe.app にまとめて署名する。
# speech は make speech でビルドしておく (make app から呼ぶと両方やる)。
#   SPEECH=path/to/speech scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEECH="${SPEECH:-$ROOT/build/speech.cpp/speech}"
APP="$ROOT/build/Koe.app"

if [ ! -x "$SPEECH" ]; then
  echo "error: $SPEECH がない (make speech でビルドする)" >&2
  exit 1
fi

swift build --package-path "$ROOT" -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Koe" "$APP/Contents/MacOS/Koe"
cp "$SPEECH" "$APP/Contents/MacOS/speech"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"

# scripts/create-signing-identity.sh で作った証明書があればそれで署名する。
# アドホック署名だと許可がビルドのハッシュ値に紐づき、作り直すたびにアクセシビリティの許可が外れる
IDENTITY="${KOE_SIGN_IDENTITY:-Koe Local Signing}"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "warning: '$IDENTITY' がないのでアドホック署名にする (scripts/create-signing-identity.sh で作れる)" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/speech"
codesign --force --sign "$IDENTITY" --identifier io.github.pokutuna.koe "$APP"

echo "built: $APP"
