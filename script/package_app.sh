#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-}"
DESTINATION="${2:-}"
APP_NAME="ClipDeck"

if [[ "$CONFIGURATION" != "debug" && "$CONFIGURATION" != "release" ]]; then
  echo "usage: $0 <debug|release> <destination/ClipDeck.app>" >&2
  exit 2
fi

if [[ -z "$DESTINATION" || "$(basename "$DESTINATION")" != "$APP_NAME.app" ]]; then
  echo "destination must end in /$APP_NAME.app" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
INFO_TEMPLATE="$ROOT_DIR/script/ClipDeck-Info.plist"
ICON_GENERATOR="$ROOT_DIR/script/generate_app_icon.swift"
REQUESTED_PARENT="$(dirname "$DESTINATION")"
mkdir -p "$REQUESTED_PARENT"
DESTINATION_PARENT="$(cd "$REQUESTED_PARENT" && pwd -P)"
DESTINATION="$DESTINATION_PARENT/$APP_NAME.app"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipdeck-package.XXXXXX")"
DELIVERY_ROOT=""
INSTALL_COMPLETE=false

cleanup() {
  if [[ -n "$DELIVERY_ROOT" && "$INSTALL_COMPLETE" != true ]]; then
    if [[ -d "$DELIVERY_ROOT/previous.app" ]]; then
      if [[ -e "$DESTINATION" ]]; then
        mv "$DESTINATION" "$DELIVERY_ROOT/failed.app"
      fi
      mv "$DELIVERY_ROOT/previous.app" "$DESTINATION"
    elif [[ -e "$DESTINATION" ]]; then
      mv "$DESTINATION" "$DELIVERY_ROOT/failed.app"
    fi
  fi
  rm -rf "$STAGING_ROOT"
  if [[ -n "$DELIVERY_ROOT" ]]; then
    rm -rf "$DELIVERY_ROOT"
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product "$APP_NAME"
BUILD_DIRECTORY="$(swift build -c "$CONFIGURATION" --show-bin-path)"
BUILD_BINARY="$BUILD_DIRECTORY/$APP_NAME"
RESOURCE_BUNDLE="$BUILD_DIRECTORY/${APP_NAME}_${APP_NAME}.bundle"

if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "missing SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi

STAGED_APP="$STAGING_ROOT/$APP_NAME.app"
STAGED_CONTENTS="$STAGED_APP/Contents"
STAGED_MACOS="$STAGED_CONTENTS/MacOS"
STAGED_RESOURCES="$STAGED_CONTENTS/Resources"
ICONSET="$STAGING_ROOT/AppIcon.iconset"

mkdir -p "$STAGED_MACOS" "$STAGED_RESOURCES"
/usr/bin/ditto "$BUILD_BINARY" "$STAGED_MACOS/$APP_NAME"
chmod +x "$STAGED_MACOS/$APP_NAME"
/usr/bin/ditto "$INFO_TEMPLATE" "$STAGED_CONTENTS/Info.plist"
/usr/bin/ditto "$RESOURCE_BUNDLE" "$STAGED_RESOURCES/$(basename "$RESOURCE_BUNDLE")"

# InfoPlist.strings must live directly in the app's localized resource folders;
# Localizable.strings remains in the SwiftPM module bundle resolved by L10n.
for LOCALIZATION in en zh-Hans; do
  RESOURCE_LOCALIZATION="$LOCALIZATION"
  if [[ "$LOCALIZATION" == "zh-Hans" ]]; then
    RESOURCE_LOCALIZATION="zh-hans"
  fi
  LOCALIZED_INFO="$RESOURCE_BUNDLE/$RESOURCE_LOCALIZATION.lproj/InfoPlist.strings"
  if [[ ! -f "$LOCALIZED_INFO" ]]; then
    echo "missing localized Info.plist strings: $LOCALIZED_INFO" >&2
    exit 1
  fi
  mkdir -p "$STAGED_RESOURCES/$LOCALIZATION.lproj"
  /usr/bin/ditto "$LOCALIZED_INFO" "$STAGED_RESOURCES/$LOCALIZATION.lproj/InfoPlist.strings"
done

/usr/bin/xcrun swift "$ICON_GENERATOR" "$ICONSET"
/usr/bin/iconutil -c icns --output "$STAGED_RESOURCES/AppIcon.icns" "$ICONSET"

/usr/bin/plutil -lint "$STAGED_CONTENTS/Info.plist" >/dev/null
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

DELIVERY_ROOT="$(mktemp -d "$DESTINATION_PARENT/.clipdeck-install.XXXXXX")"
/usr/bin/ditto "$STAGED_APP" "$DELIVERY_ROOT/new.app"

if [[ -e "$DESTINATION" ]]; then
  mv "$DESTINATION" "$DELIVERY_ROOT/previous.app"
fi
mv "$DELIVERY_ROOT/new.app" "$DESTINATION"

# A synced project directory can immediately reattach FinderInfo after it is
# cleared, making strict verification fail even though the staged bundle above
# was already signed and verified. Installed bundles live outside that file
# provider boundary, so verify those again after delivery.
case "$DESTINATION" in
  "$ROOT_DIR"/*)
    /usr/bin/xattr -cr "$DESTINATION" || true
    ;;
  *)
    /usr/bin/xattr -cr "$DESTINATION"
    /usr/bin/codesign --force --sign - "$DESTINATION"
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$DESTINATION"
    ;;
esac

INSTALL_COMPLETE=true
rm -rf "$DELIVERY_ROOT/previous.app"
echo "$DESTINATION"
