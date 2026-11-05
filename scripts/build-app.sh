#!/bin/bash
# iiire をビルドし、speech コマンドと一緒に iiire.app にまとめて署名する。
# speech は make speech でビルドしておく (make app から呼ぶと両方やる)。
#   SPEECH=path/to/speech scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEECH="${SPEECH:-$ROOT/build/speech.cpp/speech}"
APP="$ROOT/build/iiire.app"

if [ ! -x "$SPEECH" ]; then
  echo "error: $SPEECH がない (make speech でビルドする)" >&2
  exit 1
fi

swift build --package-path "$ROOT" -c release
BIN="$(swift build --package-path "$ROOT" -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/iiire" "$APP/Contents/MacOS/iiire"
cp "$SPEECH" "$APP/Contents/MacOS/speech"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT"/Resources/*.lproj "$APP/Contents/Resources/"

# scripts/create-signing-identity.sh で作った証明書があればそれで署名する。
# アドホック署名だと許可がビルドのハッシュ値に紐づき、作り直すたびにアクセシビリティの許可が外れる
IDENTITY="${IIIRE_SIGN_IDENTITY:-iiire Local Signing}"
# 証明書だけでなく秘密鍵もある (署名に使える) ものを、名前の完全一致で探す
if ! security find-identity -p codesigning | grep -qF "\"$IDENTITY\""; then
  echo "warning: '$IDENTITY' がないのでアドホック署名にする (scripts/create-signing-identity.sh で作れる)" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/speech"
codesign --force --sign "$IDENTITY" --identifier io.github.pokutuna.iiire "$APP"

echo "built: $APP"
