#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DERIVED="$ROOT/.build"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Ошибка: xcodebuild не найден. Установи Xcode и открой проект один раз." >&2
  exit 1
fi

xcodebuild \
  -project "$ROOT/SnowfallMac.xcodeproj" \
  -scheme SnowfallMac \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  build

APP="$DERIVED/Build/Products/Release/SnowfallMac.app"
if [[ ! -d "$APP" ]]; then
  echo "Сборка завершилась, но приложение не найдено: $APP" >&2
  exit 2
fi

mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/SnowfallMac.app"
ditto "$APP" "$ROOT/dist/SnowfallMac.app"
echo "Готово: $ROOT/dist/SnowfallMac.app"
