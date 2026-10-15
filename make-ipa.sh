#!/bin/bash
# Builds Rewise.ipa for Sideloadly. The .ipa is unsigned; Sideloadly signs it with your Apple ID.
# Needs Xcode (free, Mac App Store). Run from Terminal in this folder:  bash make-ipa.sh
# Optional: BUNDLE_ID=com.yourname.rewise bash make-ipa.sh
set -euo pipefail
cd "$(dirname "$0")"

if [ -d /Applications/Xcode.app ] && [[ "$(xcode-select -p 2>/dev/null)" != *Xcode*.app* ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Xcode isn't installed or set up yet."
  echo "Install Xcode from the Mac App Store and open it once. Both need an administrator account on this Mac."
  echo "If it mentions the license, an administrator runs: sudo xcodebuild -license accept"
  echo "No Xcode? Let GitHub build the .ipa instead (see README.md)."
  exit 1
fi

# Apple needs a bundle ID nobody else has registered.
BUNDLE_ID="${BUNDLE_ID:-com.martincsattos.rewise}"

echo "Building Rewise ($BUNDLE_ID). The first build takes a few minutes..."
rm -rf build/derived build/ipa Rewise.ipa
if ! xcodebuild -quiet -project Rewise.xcodeproj -scheme Rewise -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath build/derived \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build; then
  echo
  echo "Build failed. If the error says an iOS platform isn't installed, run:"
  echo "  xcodebuild -downloadPlatform iOS"
  echo "then run bash make-ipa.sh again."
  exit 1
fi

mkdir -p build/ipa/Payload
cp -R build/derived/Build/Products/Release-iphoneos/Rewise.app build/ipa/Payload/
(cd build/ipa && zip -qry ../../Rewise.ipa Payload)
rm -rf build/ipa
echo
echo "Done: $(pwd)/Rewise.ipa"
echo "Next: open Sideloadly, plug in your iPhone, drag Rewise.ipa in, enter your Apple ID, click Start."
