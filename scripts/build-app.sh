#!/bin/bash
# Unmouse.app 번들을 만든다.  사용법: scripts/build-app.sh [--install] [--run]
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Unmouse.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Unmouse "$APP/Contents/MacOS/Unmouse"
cp -R .build/release/Unmouse_Unmouse.bundle "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# 개발 인증서로 서명하면 다시 빌드해도 손쉬운 사용 / 화면 녹화 권한이 유지된다.
# 인증서가 없으면 ad-hoc 서명 (이 경우 빌드할 때마다 권한을 다시 허용해야 함).
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development|Developer ID Application/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed: ${IDENTITY:-ad-hoc})"

TARGET="$APP"
for arg in "$@"; do
    case "$arg" in
        --install)
            pkill -x Unmouse 2>/dev/null || true
            rm -rf /Applications/Unmouse.app
            cp -R "$APP" /Applications/Unmouse.app
            TARGET=/Applications/Unmouse.app
            echo "Installed to $TARGET"
            ;;
        --run)
            pkill -x Unmouse 2>/dev/null || true
            sleep 0.3
            open "$TARGET"
            ;;
    esac
done
