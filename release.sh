#!/bin/zsh
set -euo pipefail
Z=${1:+${1:A}}
cd ${0:A:h}
T=$(mktemp -d); trap 'rm -rf $T' EXIT; A=$T/dmg/ClaudeTTY.app; mkdir $T/dmg
if [[ -n $Z ]]; then
  ditto -x -k $Z $T/dmg
else
  APP=$A CLAUDETTY_RELEASE=1 ./install.sh
  [[ -n ${CLAUDETTY_SIGN-} ]] || { ditto -c -k --keepParent $A ClaudeTTY.zip; print ClaudeTTY.zip; exit; }
fi
: ${CLAUDETTY_SIGN:?a Developer ID Application identity} ${CLAUDETTY_NOTARY:?a notarytool keychain profile}
print '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.automation.apple-events</key><true/></dict></plist>' > $T/entitlements.plist
codesign --force --options runtime --timestamp --sign "$CLAUDETTY_SIGN" $A/Contents/Helpers/zmx
codesign --force --options runtime --timestamp --entitlements $T/entitlements.plist --sign "$CLAUDETTY_SIGN" $A
codesign --verify --strict $A
ln -s /Applications $T/dmg/Applications
hdiutil create -volname ClaudeTTY -srcfolder $T/dmg -fs HFS+ -format UDZO -ov ClaudeTTY.dmg
codesign --force --timestamp --sign "$CLAUDETTY_SIGN" ClaudeTTY.dmg
xcrun notarytool submit ClaudeTTY.dmg --keychain-profile "$CLAUDETTY_NOTARY" --wait
xcrun stapler staple ClaudeTTY.dmg
