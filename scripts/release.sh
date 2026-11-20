#!/bin/bash
#
# Publie une version de cactMD.
#
#   ./scripts/release.sh 1.0.1
#
# Étapes : incrémente CFBundleVersion, met à jour CFBundleShortVersionString,
# compile en Release, fabrique ./dist/cactMD-<version>.zip puis signe et
# régénère ./dist/appcast.xml avec l'outil generate_appcast livré par Sparkle.
#
# La clé privée EdDSA doit être dans le trousseau sous le compte « cactMD »
# (créée une fois avec `generate_keys --account cactMD`) ; la clé publique
# correspondante est SUPublicEDKey dans Info.plist.

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version>   (ex. : $0 1.0.1)" >&2
    exit 64
fi
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: '$VERSION' n'est pas une version valide (attendu : 1.2 ou 1.2.3)" >&2
    exit 64
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="systemMD.xcodeproj"
TARGET="MyApp"
SCHEME="MyApp"
APP_NAME="cactMD"
DIST="$ROOT/dist"
# Les archives de release publiques sont nommées d'après le tag v<version>.
DOWNLOAD_URL_PREFIX="${CACTMD_DOWNLOAD_URL_PREFIX:-https://github.com/traxqlf/cactMD/releases/download/v${VERSION}/}"

# MARKETING_VERSION / CURRENT_PROJECT_VERSION alimentent CFBundleShortVersionString
# et CFBundleVersion dans l'Info.plist généré (GENERATE_INFOPLIST_FILE = YES).
current_build="$(xcrun xcodeproj setting get --target "$TARGET" CURRENT_PROJECT_VERSION \
    | awk -F"'" '$0 ~ /Release:/ { print $2; exit }')"
if [[ ! "$current_build" =~ ^[0-9]+$ ]]; then
    echo "error: CURRENT_PROJECT_VERSION illisible ('$current_build')" >&2
    exit 1
fi
next_build=$((current_build + 1))

echo "==> ${APP_NAME} ${VERSION} (build ${next_build})"
xcrun xcodeproj setting set --target "$TARGET" CURRENT_PROJECT_VERSION "$next_build" --project "$PROJECT"
xcrun xcodeproj setting set --target "$TARGET" MARKETING_VERSION "$VERSION" --project "$PROJECT"

echo "==> Compilation Release"
xcodebuild -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' -derivedDataPath ./build-release build

APP="$ROOT/build-release/Build/Products/Release/${APP_NAME}.app"
if [[ ! -d "$APP" ]]; then
    echo "error: $APP introuvable" >&2
    exit 1
fi

built_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
built_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$built_version" != "$VERSION" || "$built_build" != "$next_build" ]]; then
    echo "error: version du bundle inattendue (${built_version} / ${built_build})" >&2
    exit 1
fi

echo "==> Archive ./dist/${APP_NAME}-${VERSION}.zip"
mkdir -p "$DIST"
rm -f "$DIST/${APP_NAME}-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/${APP_NAME}-${VERSION}.zip"

GENERATE_APPCAST="$(command -v generate_appcast || true)"
if [[ -z "$GENERATE_APPCAST" ]]; then
    GENERATE_APPCAST="$(find ./build-release/SourcePackages/artifacts ./build/SourcePackages/artifacts \
        -path '*/Sparkle/bin/generate_appcast' -type f 2>/dev/null | head -1)"
fi
if [[ -z "$GENERATE_APPCAST" ]]; then
    echo "error: generate_appcast introuvable (résolvez les paquets Sparkle d'abord)" >&2
    exit 1
fi

echo "==> Signature de l'appcast"
"$GENERATE_APPCAST" --account cactMD --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$DIST"

echo "==> Terminé : $DIST/${APP_NAME}-${VERSION}.zip et $DIST/appcast.xml"
