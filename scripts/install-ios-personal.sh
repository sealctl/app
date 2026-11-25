#!/usr/bin/env bash
# Builds the iPhone app with a free (personal) Apple developer team and installs it on your own
# iPhone or iPad over USB or Wi-Fi. For your own devices only; never shipped.
#
#   scripts/install-ios-personal.sh <team-id> <device>
#   IOS_TEAM=<team-id> IOS_DEVICE=<device> scripts/install-ios-personal.sh
#
# <team-id>: your personal team (Xcode > Settings > Accounts; or the OU of your "Apple
# Development" certificate). <device>: the device's UDID from `xcrun devicectl list devices`.
# A free team's install expires after 7 days: run this again to renew it (the app's data stays).
#
# The variant (ios/project-personal.yml, bundle id com.sealctl.app.personal) drops what a
# personal team cannot sign: push notifications (requests show while the app is open, through
# the relay socket and the catch-up on opening; nothing arrives while it is closed), Time
# Sensitive notifications, the Notification Service Extension (no answering from a banner),
# sealctl.com links (associated domains; the sealctl:// scheme and the in-app scanner still
# pair) and the app group (files stay in the app's own container).
#
# Optional: CONFIGURATION (Release), DERIVED_DATA (ios/build/personal/DerivedData),
# RELAY_URL (https://relay.sealctl.com; ignores ios/Config/Local.xcconfig), CORE=1 to rebuild
# the Rust core, LAUNCH=0 to skip opening the app after the install.
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=${1:-${IOS_TEAM:-}}
DEVICE=${2:-${IOS_DEVICE:-}}
if [ -z "$TEAM" ] || [ -z "$DEVICE" ]; then
  sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 2
fi
CONFIGURATION=${CONFIGURATION:-Release}
DERIVED_DATA=${DERIVED_DATA:-ios/build/personal/DerivedData}
RELAY_URL=${RELAY_URL:-https://relay.sealctl.com}
BUNDLE_ID=com.sealctl.app.personal

# xcodebuild and devicectl need Xcode, not the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcode-select -p 2>/dev/null | grep -q '\.app/'; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# The Rust core for iPhone and iPad, unless it is already built (CORE=1 rebuilds it, after a
# core update). build-core-ios.sh replaces the whole XCFramework, so keep the slices it has.
XCF=ios/Packages/SealCore/SealctlFFI.xcframework
if [ ! -d "$XCF/ios-arm64" ] || [ "${CORE:-0}" = 1 ]; then
  platforms=ios
  [ -d "$XCF/ios-arm64_x86_64-simulator" ] && platforms+=" sim"
  [ -d "$XCF/macos-arm64" ] && platforms+=" macos"
  PLATFORMS=$platforms scripts/build-core-ios.sh
fi

(cd ios && xcodegen generate --quiet --spec project-personal.yml)

xcodebuild -project ios/sealctl-personal.xcodeproj -scheme sealctl \
  -configuration "$CONFIGURATION" -destination "id=$DEVICE" \
  -derivedDataPath "$DERIVED_DATA" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" SEALCTL_RELAY_URL="$RELAY_URL" SEALCTL_TEST_DELAY_SECS=0 \
  -quiet build

APP="$DERIVED_DATA/Build/Products/$CONFIGURATION-iphoneos/sealctl.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
if [ "${LAUNCH:-1}" != 0 ]; then
  xcrun devicectl device process launch --device "$DEVICE" --terminate-existing "$BUNDLE_ID" || {
    echo "Installed, but iOS did not open it (the reason is above). Unlock the device; the first" >&2
    echo "time, also trust your Apple ID in Settings > General > VPN & Device Management and turn" >&2
    echo "on Settings > Privacy & Security > Developer Mode. Then open sealctl on the device." >&2
    exit 1
  }
fi
echo "Installed $BUNDLE_ID. Renew within 7 days by running this again."
