#!/bin/zsh
set -euo pipefail
APP=${APP:-~/Applications/ClaudeTTY.app}
cd ${0:A:h}
SIGN=${CLAUDETTY_SIGN:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}
if [[ -z $SIGN ]]; then
  SIGN="ClaudeTTY Local"
  if ! security find-certificate -c "$SIGN" >/dev/null 2>&1; then
    read -q "?No code signing identity. Make \"$SIGN\" in your login keychain? [y/N] " || { echo; echo "Set CLAUDETTY_SIGN to an identity, or answer y."; exit 1; }
    echo; T=$(mktemp -d)
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$SIGN" -addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=critical,codeSigning -keyout $T/key -out $T/cert 2>/dev/null
    /usr/bin/openssl pkcs12 -export -inkey $T/key -in $T/cert -out $T/id.p12 -passout pass:x
    security import $T/id.p12 -P x -T /usr/bin/codesign; rm -rf $T
  fi
fi
swift build -c release
rm -rf "${APP:?}.new" "${APP:?}.old"; mkdir -p $APP.new/Contents/MacOS
cp .build/release/ClaudeTTY $APP.new/Contents/MacOS/
D=~/Library/Caches/claudetty-deps; mkdir -p $APP.new/Contents/{Helpers,Resources}
cp $D/zmx/zmx $APP.new/Contents/Helpers/; cp -R $D/ghostty/zig-out/share/{ghostty,terminfo} $APP.new/Contents/Resources/
I=$D/icon-$(shasum icon.swift | cut -c1-12).icns
[[ -f $I ]] || { rm -rf $D/icon.iconset; swift icon.swift $D/icon.iconset && iconutil -c icns $D/icon.iconset -o $I; }
cp $I $APP.new/Contents/Resources/ClaudeTTY.icns
M=$APP.new/Contents/Resources/plugin; mkdir -p $M/.claude-plugin; cp -R plugin $M/claudetty
print '{"name":"claudetty","owner":{"name":"ClaudeTTY"},"plugins":[{"name":"claudetty","source":"./claudetty"}]}' > $M/.claude-plugin/marketplace.json
plutil -replace version -string $(cd plugin && find . -type f | sort | xargs cat | shasum | cut -c1-12) $M/claudetty/.claude-plugin/plugin.json
P=$APP.new/Contents/Info.plist; plutil -create xml1 $P
for k v in CFBundleIdentifier dev.claudetty.app CFBundleName ClaudeTTY CFBundleShortVersionString 1.1.0 CFBundleVersion 2 CFBundleExecutable ClaudeTTY CFBundleIconFile ClaudeTTY CFBundlePackageType APPL LSMinimumSystemVersion 26.0; do plutil -insert $k -string $v $P; done
[[ -n ${CLAUDETTY_RELEASE-} ]] || plutil -insert ClaudeTTYSource -string $PWD $P
for k in AppBundles AppData AppleEvents AppleMusic AudioCapture BluetoothAlways BluetoothWhileInUse Calendars CalendarsFullAccess CalendarsWriteOnlyAccess \
  Camera Contacts DesktopFolder DocumentsFolder DownloadsFolder FaceID FileProviderDomain FileProviderPresence FinancialData FocusStatus HomeKit LocalNetwork \
  Location LocationWhenInUse Microphone MicrophoneInjection Motion NetworkVolumes PhotoLibrary PhotoLibraryAdd Reminders RemindersFullAccess RemovableVolumes \
  Siri SpeechRecognition SystemAdministration SystemPolicyAppDataDetailed; do
  plutil -insert NS${k}UsageDescription -string "A program running in a ClaudeTTY tab asked for this." $P
done
K=$APP.new/Contents/Library/LaunchAgents; mkdir -p $K; K=$K/dev.claudetty.keeper.plist; plutil -create xml1 $K
plutil -insert Label -string dev.claudetty.keeper $K; plutil -insert BundleProgram -string Contents/MacOS/ClaudeTTY $K
plutil -insert ProgramArguments -array $K; plutil -insert ProgramArguments -string ClaudeTTY -append $K; plutil -insert ProgramArguments -string --keeper -append $K
plutil -insert RunAtLoad -bool true $K; plutil -insert KeepAlive -bool true $K; plutil -insert AbandonProcessGroup -bool true $K
plutil -insert ProcessType -string Interactive $K
codesign --force --timestamp=none --sign "$SIGN" $APP.new/Contents/Helpers/zmx $APP.new
codesign --verify --strict $APP.new
if [[ -d $APP ]]; then mv $APP $APP.old; fi
mv $APP.new $APP
rm -rf "${APP:?}.old"
[[ -z ${CLAUDETTY_RELEASE-} ]] || exit 0
launchctl kickstart -k gui/$UID/dev.claudetty.keeper 2>/dev/null || true
