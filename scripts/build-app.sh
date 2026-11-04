#!/bin/bash
# Koe.app を作る。speech.cpp をソースからビルドして .app に同梱する。
#   scripts/build-app.sh [speech.cpp のディレクトリ]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SPEECH_CPP="${1:-${SPEECH_CPP:-$HOME/ghq/github.com/nyosegawa/speech.cpp}}"
SPEECH_BUILD="$SPEECH_CPP/build-koe"
APP="$ROOT/build/Koe.app"

if [ ! -d "$SPEECH_CPP" ]; then
  git clone --recurse-submodules https://github.com/nyosegawa/speech.cpp.git "$SPEECH_CPP"
fi

# OpenMP を切ると Homebrew の libomp に依存しない単体の実行ファイルになる
if [ ! -x "$SPEECH_BUILD/speech" ] || [ -n "${REBUILD_SPEECH:-}" ]; then
  cmake -S "$SPEECH_CPP" -B "$SPEECH_BUILD" -DCMAKE_BUILD_TYPE=Release -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF
  cmake --build "$SPEECH_BUILD" --config Release -j
fi

swift build --package-path "$ROOT" -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/Koe" "$APP/Contents/MacOS/Koe"
cp "$SPEECH_BUILD/speech" "$APP/Contents/MacOS/speech"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# scripts/create-signing-identity.sh で作った証明書があればそれで署名する。
# アドホック署名だと許可がビルドのハッシュ値に紐づき、作り直すたびにアクセシビリティの許可が外れる
IDENTITY="${KOE_SIGN_IDENTITY:-Koe Local Signing}"
if ! security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  echo "warning: '$IDENTITY' がないのでアドホック署名にする (scripts/create-signing-identity.sh で作れる)" >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/speech"
codesign --force --sign "$IDENTITY" --identifier net.pokutuna.koe "$APP"

echo "built: $APP"
