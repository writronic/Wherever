#!/bin/bash
set +x
set -euo pipefail
umask 022

APP_NAME="Wherever"
BUNDLE_ID="com.writronic.wherever"
NOTARY_PROFILE="Wherever"
FLOOR="13.0"
MINIMUM_TAG="<sparkle:minimumSystemVersion>13.0.0</sparkle:minimumSystemVersion>"

SPARKLE_KEY="${SPARKLE_PRIVATE_KEY:-}"
SPARKLE_KEY="${SPARKLE_KEY#"${SPARKLE_KEY%%[![:space:]]*}"}"
SPARKLE_KEY="${SPARKLE_KEY%"${SPARKLE_KEY##*[![:space:]]}"}"
unset SPARKLE_PRIVATE_KEY

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

refuse() {
    echo "$1" >&2
    exit 1
}

OUTPUT=""
KEYCHAIN=""
TAG=""
HAS_TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
    --output) [ $# -ge 2 ] || refuse "arguments: refused; --output needs a folder"; OUTPUT="$2"; shift 2 ;;
    --keychain) [ $# -ge 2 ] || refuse "arguments: refused; --keychain needs a file"; KEYCHAIN="$2"; shift 2 ;;
    --tag) [ $# -ge 2 ] || refuse "arguments: refused; --tag needs a tag"; TAG="$2"; HAS_TAG=1; shift 2 ;;
    *) refuse "arguments: refused; use --output ABSOLUTE_DIRECTORY --keychain ABSOLUTE_FILE [--tag vVERSION]" ;;
    esac
done

echo "▶ Phase 0: Checking the release inputs..."

[ -z "${XCODE_XCCONFIG_FILE:-}" ] || refuse "environment: refused; XCODE_XCCONFIG_FILE overrides reviewed settings"
command -v create-dmg >/dev/null 2>&1 || refuse "create-dmg: refused; run npm install --global create-dmg@8.1.0 --allow-scripts=fs-xattr,macos-alias"

one_setting() {
    local values
    values="$(sed -n "s/^[[:space:]]*$1 = \(.*\);\$/\1/p" "$APP_NAME.xcodeproj/project.pbxproj" | sort -u)"
    [ -n "$values" ] && [ "$(printf '%s\n' "$values" | wc -l | tr -d ' ')" = 1 ] || refuse "project: refused; expected one $1"
    printf '%s' "$values"
}
VERSION="$(one_setting MARKETING_VERSION)"
BUILD="$(one_setting CURRENT_PROJECT_VERSION)"
[[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || refuse "version: refused; expected a stable numeric major.minor.patch"
[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || refuse "build: refused; expected a positive integer"

if [ -n "$HAS_TAG" ] && [ "$TAG" != "v$VERSION" ]; then
    refuse "tag: refused; expected v$VERSION"
fi

[[ "$KEYCHAIN" == /* ]] && [ -f "$KEYCHAIN" ] || refuse "keychain: refused; supply --keychain with an absolute path to an existing keychain file"

[ -f appcast.xml ] || refuse "build: refused; appcast.xml is missing"
LAST_BUILD=0
for value in $(sed -n 's/.*<sparkle:version>[[:space:]]*\([^<[:space:]]*\)[[:space:]]*<\/sparkle:version>.*/\1/p' appcast.xml); do
    [[ "$value" =~ ^[0-9]+$ ]] || refuse "build: refused; appcast.xml holds a sparkle:version that is not a number"
    if [ "$((10#$value))" -gt "$LAST_BUILD" ]; then LAST_BUILD="$((10#$value))"; fi
done
[ "$BUILD" -gt "$LAST_BUILD" ] || refuse "build: refused; $BUILD is not higher than the appcast's last build ($LAST_BUILD)"

clean_source() {
    [ -z "$(git ls-files -v -- . | grep '^[a-zS] ' || true)" ] || refuse "source: refused; build inputs use assume-unchanged or skip-worktree"
    [ -z "$(git status --porcelain --untracked-files=no)" ] || refuse "source: refused; tracked tree is dirty"
    [ -z "$(git ls-files --others --exclude-standard -- .)" ] || refuse "source: refused; untracked build inputs"
    [ -z "$(git ls-files --others --ignored --exclude-standard -- '*.swift')" ] || refuse "source: refused; ignored Swift files"
}
clean_source
HEAD_COMMIT="$(git rev-parse HEAD)"
REPOSITORY="$(cd "$(git rev-parse --show-toplevel)" && pwd -P)"

[[ "$OUTPUT" == /* ]] || refuse "output: refused; supply --output with an absolute path"
PARENT="$(cd "$(dirname "$OUTPUT")" 2>/dev/null && pwd -P)" || refuse "output: refused; parent directory must exist"
OUTPUT="$PARENT/$(basename "$OUTPUT")"
case "$OUTPUT/" in
"$REPOSITORY"/*) refuse "output: refused; path is inside the repository" ;;
esac
if [ -L "$OUTPUT" ] || { [ -e "$OUTPUT" ] && [ ! -d "$OUTPUT" ]; }; then refuse "output: refused; destination is not a directory"; fi
if [ -e "$OUTPUT/$APP_NAME.dmg" ] || [ -L "$OUTPUT/$APP_NAME.dmg" ]; then refuse "output: refused; $APP_NAME.dmg already exists"; fi
[ -f LICENSE ] || refuse "license: refused; LICENSE missing"

KEPT="${WHEREVER_RELEASE_BUILD:-}"
[[ "$KEPT" == /* ]] || refuse "inputs: refused; supply WHEREVER_RELEASE_BUILD as an absolute folder"
[ -n "$SPARKLE_KEY" ] || refuse "inputs: refused; supply SPARKLE_PRIVATE_KEY"
[[ "$SPARKLE_KEY" =~ ^[A-Za-z0-9+/]{20,}={0,2}$ ]] || refuse "inputs: refused; SPARKLE_PRIVATE_KEY is not a base64 key"
IDENTITY="${WHEREVER_SIGNING_IDENTITY:-}"
TEAM="${WHEREVER_APPLE_TEAM_ID:-}"
[[ "$IDENTITY" =~ ^([A-Fa-f0-9]{40}|Developer\ ID\ Application:\ .+)$ ]] || refuse "inputs: refused; supply a named Developer ID Application identity or SHA-1 selector in WHEREVER_SIGNING_IDENTITY"
[[ "$TEAM" =~ ^[A-Z0-9]{10}$ ]] || refuse "inputs: refused; invalid WHEREVER_APPLE_TEAM_ID"

NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE" --keychain "$KEYCHAIN")
xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 || refuse "notary profile: refused; store the $NOTARY_PROFILE profile with notarytool store-credentials"

echo "Phase 0 complete: version $VERSION, build $BUILD."
echo ""

DERIVED="$KEPT/derived"
mkdir -p "$KEPT/cargo"
WORK="$(mktemp -d "$KEPT/release-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUTPUT"

echo "▶ Phase 1: Building $APP_NAME (arm64 and x86_64)..."

CARGO_TARGET_DIR="$KEPT/cargo" /bin/sh scripts/build-engine.sh >"$WORK/engine.log" 2>&1 || { tail -30 "$WORK/engine.log"; refuse "engine: failed"; }
clean_source

xcodebuild build \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED" \
    -disableAutomaticPackageResolution \
    COMPILER_INDEX_STORE_ENABLE=NO \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO >"$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; refuse "build: failed"; }

APP_PATH="$(cd "$DERIVED/Build/Products/Release/$APP_NAME.app" 2>/dev/null && pwd -P)" || refuse "build: refused; $APP_NAME.app missing"
INFO="$APP_PATH/Contents/Info.plist"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$INFO" 2>/dev/null || true; }
if [ "$(plist CFBundleIdentifier)" != "$BUNDLE_ID" ] || [ "$(plist CFBundleExecutable)" != "$APP_NAME" ] || [ "$(plist CFBundleShortVersionString)" != "$VERSION" ] ||
    [ "$(plist CFBundleVersion)" != "$BUILD" ] || [ "$(plist LSMinimumSystemVersion)" != "$FLOOR" ]; then
    refuse "bundle: refused; identifier, executable, version, build or LSMinimumSystemVersion mismatch"
fi

SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/sign_update" ] && [ -x "$SPARKLE_BIN/generate_appcast" ] || refuse "sparkle: refused; sign_update or generate_appcast missing from the build's package checkout"

echo "Phase 1 complete: $APP_NAME $VERSION ($BUILD) built."
echo ""

echo "▶ Phase 2: Signing with Developer ID Application, inside out..."

deepest_first() { awk -F/ '{ print NF "\t" $0 }' | sort -rn | cut -f2-; }

find "$APP_PATH" -type l >"$WORK/links"
while IFS= read -r link; do
    target="$(realpath "$link" 2>/dev/null)" || refuse "bundle: refused; broken symlink"
    case "$target/" in
    "$APP_PATH"/*) ;;
    *) refuse "bundle: refused; escaping symlink" ;;
    esac
done <"$WORK/links"

find "$APP_PATH" -type f >"$WORK/files"
: >"$WORK/images"
while IFS= read -r file; do
    case "$(od -An -tx1 -N4 "$file" | tr -d ' \n')" in
    cafebabe|bebafeca|cafebabf|bfbafeca|feedface|cefaedfe|feedfacf|cffaedfe)
        case "$(file -b "$file")" in *Mach-O*) echo "$file" >>"$WORK/images" ;; esac ;;
    esac
done <"$WORK/files"

find "$APP_PATH" -mindepth 1 -type d \( -name "*.framework" -o -name "*.app" -o -name "*.xpc" -o -name "*.appex" -o -name "*.bundle" \) >"$WORK/folders"
: >"$WORK/bundles"
while IFS= read -r bundle; do
    if grep -qF "$bundle/" "$WORK/images"; then echo "$bundle" >>"$WORK/bundles"; fi
done <"$WORK/folders"

awk -F/ '{ n = NF; b = $n
    if ($(n - 1) == "MacOS" && $(n - 2) == "Contents" && ($(n - 3) == b ".app" || $(n - 3) == b ".xpc" || $(n - 3) == b ".appex")) next
    if ($(n - 2) == "Versions" && $(n - 3) == b ".framework") next
    print }' "$WORK/images" >"$WORK/loose"

CODESIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY" --keychain "$KEYCHAIN")
mkdir -p "$APP_PATH/Contents/Resources"
cp LICENSE "$APP_PATH/Contents/Resources/LICENSE"
cat "$WORK/loose" "$WORK/bundles" | deepest_first | while IFS= read -r path; do
    "${CODESIGN[@]}" "$path" >/dev/null 2>&1 || refuse "sign nested code: failed"
done
"${CODESIGN[@]}" --entitlements Config/Wherever.entitlements "$APP_PATH" >/dev/null 2>&1 || refuse "sign app: failed"

echo "Phase 2 complete: $(wc -l <"$WORK/loose" | tr -d ' ') loose images, $(wc -l <"$WORK/bundles" | tr -d ' ') bundles, then the app."
echo ""

echo "▶ Phase 3: Verifying signatures, architectures and minimum macOS..."

version_order() {
    local a b rest
    IFS=. read -r a1 a2 a3 rest <<<"$1.0.0"
    IFS=. read -r b1 b2 b3 rest <<<"$2.0.0"
    for pair in "$a1 $b1" "$a2 $b2" "$a3 $b3"; do
        read -r a b <<<"$pair"
        if [ "$((10#${a:-0}))" -lt "$((10#${b:-0}))" ]; then echo -1; return; fi
        if [ "$((10#${a:-0}))" -gt "$((10#${b:-0}))" ]; then echo 1; return; fi
    done
    echo 0
}

MAIN="$APP_PATH/Contents/MacOS/$APP_NAME"
TOOL="$APP_PATH/Contents/Helpers/wherever"
HELPER="$APP_PATH/Contents/Library/LoginItems/WhereverHelper.app/Contents/MacOS/WhereverHelper"
grep -qxF "$MAIN" "$WORK/images" || refuse "bundle: refused; main executable missing"
grep -qxF "$TOOL" "$WORK/images" || refuse "bundle: refused; command-line tool missing"
grep -qxF "$HELPER" "$WORK/images" || refuse "bundle: refused; helper app missing"

while IFS= read -r image; do
    archs="$(lipo -archs "$image" 2>/dev/null)" || refuse "architectures: refused; lipo cannot read an image"
    [ "$(printf '%s\n' $archs | sort | tr '\n' ' ')" = "arm64 x86_64 " ] || refuse "architectures: refused; require arm64 and x86_64"
    details="$(codesign -d --verbose=4 "$image" 2>&1)" || refuse "signing: refused; an image is not signed"
    if ! grep -q '^Authority=Developer ID Application: ' <<<"$details" || ! grep -qx "TeamIdentifier=$TEAM" <<<"$details" ||
        ! grep -q '^Timestamp=.' <<<"$details" || ! grep -Eq 'flags=.*[(,]runtime[),]' <<<"$details"; then
        refuse "signing: refused; Developer ID, team, timestamp or hardened runtime missing"
    fi
    for arch in arm64 x86_64; do
        minos="$(otool -arch "$arch" -l "$image" 2>/dev/null | awk '/cmd LC_BUILD_VERSION|cmd LC_VERSION_MIN_MACOSX/ { found = 1 } found && !done && ($1 == "minos" || $1 == "version") { print $2; done = 1 }')"
        [[ "$minos" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || refuse "deployment: refused; no minimum version"
        order="$(version_order "$minos" "$FLOOR")"
        [ "$order" != 1 ] || refuse "deployment: refused; minimum exceeds macOS $FLOOR"
        case "$image" in
        "$MAIN"|"$TOOL"|"$HELPER"|*/WhereverKit.framework/*) [ "$order" = 0 ] || refuse "deployment: refused; minimum must be macOS $FLOOR" ;;
        esac
    done
done <"$WORK/images"

codesign --verify --deep --strict --all-architectures "$APP_PATH" >/dev/null 2>&1 || refuse "codesign --verify --deep --strict: failed"

echo "Phase 3 complete: $(wc -l <"$WORK/images" | tr -d ' ') images, arm64 and x86_64, minimum macOS $FLOOR."
echo ""

notarize() {
    local result status id
    result="$(xcrun notarytool submit "$1" "${NOTARY_AUTH[@]}" --wait --timeout 30m --output-format json 2>/dev/null || true)"
    status="$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$result" | head -1)"
    id="$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([0-9a-fA-F-]\{36\}\)".*/\1/p' <<<"$result" | head -1)"
    echo "  notary $2: status ${status:-Unknown}; id ${id:-none}"
    if [ "$status" != "Accepted" ] || [ -z "$id" ]; then
        if [ -n "$id" ]; then xcrun notarytool log "$id" "${NOTARY_AUTH[@]}" || true; fi
        refuse "notary $2: stopped; inspect the submission before any new upload"
    fi
}

echo "▶ Phase 4: Notarizing the app..."

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$WORK/$APP_NAME-notarize.zip"
notarize "$WORK/$APP_NAME-notarize.zip" app
xcrun stapler staple "$APP_PATH" >/dev/null || refuse "staple app: failed"
xcrun stapler validate "$APP_PATH" >/dev/null || refuse "validate app: failed"

echo "Phase 4 complete: app notarized and stapled."
echo ""

echo "▶ Phase 5: Creating, signing and notarizing $APP_NAME.dmg..."

STAGING="$WORK/dmg"
mkdir "$STAGING"
DMG="$WORK/$APP_NAME.dmg"
for attempt in 1 2 3; do
    rm -f "$STAGING"/*.dmg
    if (cd "$STAGING" && create-dmg --no-code-sign --dmg-title="$APP_NAME" --no-version-in-filename "$APP_PATH" "$STAGING" >/dev/null 2>&1); then
        made=("$STAGING"/*.dmg)
        [ "${#made[@]}" = 1 ] && [ -f "${made[0]}" ] || refuse "create DMG: refused; expected one DMG"
        mv "${made[0]}" "$DMG"
        break
    fi
    echo "  create DMG try $attempt: did not finish"
    [ "$attempt" = 3 ] && { rm -f "$STAGING"/*.dmg; refuse "create DMG: failed after 3 tries"; }
    sleep 5
done

codesign --force --timestamp --sign "$IDENTITY" --keychain "$KEYCHAIN" -i "$BUNDLE_ID.dmg" "$DMG" >/dev/null 2>&1 || refuse "sign DMG: failed"
notarize "$DMG" dmg
xcrun stapler staple "$DMG" >/dev/null || refuse "staple DMG: failed"
xcrun stapler validate "$DMG" >/dev/null || refuse "validate DMG: failed"
codesign --verify --strict "$DMG" >/dev/null 2>&1 || refuse "DMG codesign --verify --strict: failed"
DMG_DETAILS="$(codesign -d --verbose=4 "$DMG" 2>&1)" || refuse "DMG: refused; no signature"
if ! grep -q '^Authority=Developer ID Application: ' <<<"$DMG_DETAILS" || ! grep -q '^Timestamp=.' <<<"$DMG_DETAILS"; then
    refuse "DMG: refused; needs a timestamped Developer ID signature"
fi
spctl --assess --type execute "$APP_PATH" >/dev/null 2>&1 || refuse "spctl: failed"
hdiutil verify "$DMG" >/dev/null 2>&1 || refuse "hdiutil verify: failed"

echo "Phase 5 complete: $APP_NAME.dmg signed, notarized, stapled and verified."
echo ""

echo "▶ Phase 6: Signing the Sparkle update and writing appcast.xml..."

sparkle_tool() {
    local tool="$1"
    shift
    printf '%s' "$SPARKLE_KEY" | "$SPARKLE_BIN/$tool" --ed-key-file - "$@" 2>/dev/null
}

SIGNED="$(sparkle_tool sign_update "$DMG")" || refuse "sparkle: sign_update failed; its output is not shown"
SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNED" | head -1)"
LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$SIGNED" | head -1)"
[ -n "$SIGNATURE" ] && [ -n "$LENGTH" ] || refuse "sparkle: refused; sign_update printed no signature and length"
[ "$LENGTH" = "$(stat -f%z "$DMG")" ] || refuse "sparkle: refused; sign_update length differs from the DMG size"

DOWNLOAD="https://github.com/writronic/Wherever/releases/download/v$VERSION/"
mkdir "$WORK/appcast"
cp "$DMG" "$WORK/appcast/$APP_NAME.dmg"
APPCAST="$WORK/appcast.xml"
sparkle_tool generate_appcast --download-url-prefix "$DOWNLOAD" -o "$APPCAST" "$WORK/appcast" >/dev/null || refuse "appcast: generate_appcast failed; its output is not shown"
[ -f "$APPCAST" ] || refuse "appcast: refused; generate_appcast wrote no appcast.xml"

if ! grep -q '<sparkle:minimumSystemVersion>' "$APPCAST"; then
    grep -q '</item>' "$APPCAST" || refuse "appcast: refused; no item to hold minimumSystemVersion"
    sed -i '' "s#</item>#$MINIMUM_TAG</item>#" "$APPCAST"
fi
sed -i '' 's#<sparkle:minimumSystemVersion>[[:space:]]*13\.0[[:space:]]*</sparkle:minimumSystemVersion>#'"$MINIMUM_TAG"'#' "$APPCAST"

[ "$(grep -Eo '<item[ >]' "$APPCAST" | wc -l | tr -d ' ')" = 1 ] || refuse "appcast: refused; expected exactly one item"
grep -qF "$MINIMUM_TAG" "$APPCAST" && [ "$(grep -o '<sparkle:minimumSystemVersion>' "$APPCAST" | wc -l | tr -d ' ')" = 1 ] || refuse "appcast: refused; minimumSystemVersion is not 13.0.0"
grep -Eq "<sparkle:version>[[:space:]]*$BUILD[[:space:]]*</sparkle:version>" "$APPCAST" || refuse "appcast: refused; sparkle:version is not the build"
grep -Eq "<sparkle:shortVersionString>[[:space:]]*$VERSION[[:space:]]*</sparkle:shortVersionString>" "$APPCAST" || refuse "appcast: refused; sparkle:shortVersionString is not the version"
ENCLOSURE="$(tr '\n' ' ' <"$APPCAST" | grep -o '<enclosure[^>]*>' | head -1)"
grep -qF "url=\"$DOWNLOAD$APP_NAME.dmg\"" <<<"$ENCLOSURE" || refuse "appcast: refused; enclosure url is not the release download"
grep -qF "length=\"$LENGTH\"" <<<"$ENCLOSURE" && grep -qF "sparkle:edSignature=\"$SIGNATURE\"" <<<"$ENCLOSURE" || refuse "appcast: refused; enclosure differs from sign_update"

echo "Phase 6 complete: one item, sparkle:version $BUILD, minimumSystemVersion 13.0.0."
echo ""

clean_source
[ "$(git rev-parse HEAD)" = "$HEAD_COMMIT" ] || refuse "source: refused; source changed during release"
mv "$DMG" "$OUTPUT/$APP_NAME.dmg"
mv "$APPCAST" "$OUTPUT/appcast.xml"

echo "SUCCESS: $OUTPUT/$APP_NAME.dmg ($(du -h "$OUTPUT/$APP_NAME.dmg" | cut -f1)) and $OUTPUT/appcast.xml"
