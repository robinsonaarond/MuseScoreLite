#!/bin/bash

# LONG_NAME is used for dmg naming, LONGER_NAME is used when renaming the .app later. LONGER_NAME can't be updated
# to "MuseScore Studio" yet, as it will prevent users from seeing the prompt asking them to replace an old version
# of MuseScore (potentially resulting in 2 copies of version 4). This will be updated on the next major release.
APPNAME=mscore
LONG_NAME="MuseScore-Studio"
LONGER_NAME="MuseScore 4"
VERSION=0
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --app_name) APPNAME="$2"; shift ;;
        --long_name) LONG_NAME="$2"; shift ;;
        --longer_name) LONGER_NAME="$2"; shift ;;
        --version) VERSION=$2; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ "$VERSION" = 0 ]; then
    VERSION=$(cmake -P "$SCRIPT_DIR/../config.cmake" | sed -n -e "s/^.*VERSION  *//p")
fi

echo "APPNAME: $APPNAME"
echo "LONG_NAME: $LONG_NAME"
echo "LONGER_NAME: $LONGER_NAME"
echo "VERSION: $VERSION"

WORKING_DIRECTORY=applebuild
BACKGROUND=buildscripts/packaging/macOS/musescore-dmg-background.tiff
APP_PATH="${WORKING_DIRECTORY}/${APPNAME}.app"

if [ ! -d "${APP_PATH}" ]; then
    mapfile -t detected_apps < <(find "${WORKING_DIRECTORY}" -maxdepth 1 -mindepth 1 -type d -name "*.app" | sort)
    if [ "${#detected_apps[@]}" -eq 1 ]; then
        APP_PATH="${detected_apps[0]}"
        APPNAME="$(basename "${APP_PATH}" .app)"
        echo "Auto-detected app bundle: ${APP_PATH}"
    elif [ "${#detected_apps[@]}" -eq 0 ]; then
        echo "No .app found in ${WORKING_DIRECTORY}"
        exit 1
    else
        echo "Multiple .app bundles found in ${WORKING_DIRECTORY}; pass --app_name"
        printf '  %s\n' "${detected_apps[@]}"
        exit 1
    fi
fi

VOLNAME=${LONG_NAME}-${VERSION}
DMGNAME=${VOLNAME}Uncompressed.dmg
COMPRESSEDDMGNAME=${VOLNAME}.dmg

rm "${WORKING_DIRECTORY}/${COMPRESSEDDMGNAME}"

# Tip: increase the size if error on copy or macdeployqt
hdiutil create -size 750m -fs HFS+ -volname "${VOLNAME}" "${WORKING_DIRECTORY}/${DMGNAME}"

# Mount the disk image
hdiutil attach "${WORKING_DIRECTORY}/${DMGNAME}"

# Obtain device information
DEVS=$(hdiutil attach "${WORKING_DIRECTORY}/${DMGNAME}" | cut -f 1)
DEV=$(echo "$DEVS" | cut -f 1 -d ' ')
VOLUME=$(mount | grep "${DEV}" | cut -f 3 -d ' ')
APP_BUNDLE_PATH="${VOLUME}/${APPNAME}.app"

# copy in the application bundle
cp -Rp "${APP_PATH}" "${APP_BUNDLE_PATH}"
APP_EXECUTABLE_PATH="$(find "${APP_BUNDLE_PATH}/Contents/MacOS" -maxdepth 1 -type f | head -n 1)"
if [ -z "${APP_EXECUTABLE_PATH}" ]; then
    echo "Failed to find executable in ${APP_BUNDLE_PATH}/Contents/MacOS"
    exit 1
fi

# Deploy
echo "otool -L pre-macdeployqt"
otool -L "${APP_EXECUTABLE_PATH}"

echo "macdeployqt"
macdeployqt "${APP_BUNDLE_PATH}" \
    -verbose=2 \
    -qmldir=. \
    -sign-for-notarization="Developer ID Application: MuseScore"

echo "Fix Homebrew install names and rpaths"
"${SCRIPT_DIR}/fix_homebrew_links.sh" "${APP_BUNDLE_PATH}"

echo "otool -L post-macdeployqt"
otool -L "${APP_EXECUTABLE_PATH}"

# Remove dSYM files
echo "Remove dSYM files"
find "${APP_BUNDLE_PATH}/Contents" -type d -name "*.dSYM" -exec rm -r {} +

# Rename Resources/qml to Resources/qml_mu. This way, VST3 plugins that also use QML
# won't find these QML files, to prevent crashes because of conflicts.
# https://github.com/musescore/MuseScore/issues/21372
# https://github.com/musescore/MuseScore/issues/24331
echo "Rename Resources/qml to Resources/qml_mu"
if [ -d "${APP_BUNDLE_PATH}/Contents/Resources/qml" ]; then
    mv "${APP_BUNDLE_PATH}/Contents/Resources/qml" "${APP_BUNDLE_PATH}/Contents/Resources/qml_mu"
fi
if [ -f "${APP_BUNDLE_PATH}/Contents/Resources/qt.conf" ]; then
    sed -i '' 's:Resources/qml:Resources/qml_mu:g' "${APP_BUNDLE_PATH}/Contents/Resources/qt.conf"
fi

# Re-sign main app after renaming qml folder
echo "Re-sign main app after renaming qml folder"
codesign --force \
    --options runtime \
    --entitlements "${WORKING_DIRECTORY}/../buildscripts/packaging/macOS/entitlements.plist" \
    -s "Developer ID Application: MuseScore" \
    "${APP_BUNDLE_PATH}"

echo "Codesign verify"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE_PATH}"

echo "spctl"
spctl --assess --type execute -vvv "${APP_BUNDLE_PATH}"

# Rename
TARGET_APP_BUNDLE_PATH="${APP_BUNDLE_PATH}"
if [ "${APPNAME}" != "${LONGER_NAME}" ]; then
    echo "Rename ${APPNAME}.app to ${VOLUME}/${LONGER_NAME}.app"
    TARGET_APP_BUNDLE_PATH="${VOLUME}/${LONGER_NAME}.app"
    mv "${APP_BUNDLE_PATH}" "${TARGET_APP_BUNDLE_PATH}"
fi

# Copy in background image
echo "Copy in background image"
mkdir -p "${VOLUME}/Pictures"
cp "${BACKGROUND}" "${VOLUME}/Pictures/background.tiff"

# Add symlink to Applications folder
echo "Add symlink to Applications folder"
ln -s /Applications/ "${VOLUME}/Applications"

# Decorate disk image
echo "Decorate disk image"
osascript <<-EOF
tell application "Finder"
    set f to POSIX file ("${VOLUME}" as string) as alias
    tell folder f
        open
        tell container window
            set toolbar visible to false
            set statusbar visible to false
            set current view to icon view
            delay 1 -- sync
            set the bounds to {0, 0, 589, 435}
        end tell
        delay 1 -- sync
        set icon size of the icon view options of container window to 120
        set arrangement of the icon view options of container window to not arranged
        set position of item "$(basename "${TARGET_APP_BUNDLE_PATH}")" to {150, 200}
        close
        set position of item "Applications" to {439, 200}
        open
        set background picture of the icon view options of container window to file "background.tiff" of folder "Pictures"
        set the bounds of the container window to {0, 0, 589, 435}
        update without registering applications
        delay 5 -- sync
        close
    end tell
    delay 5 -- sync
end tell
EOF

mv "${VOLUME}/Pictures" "${VOLUME}/.Pictures"

echo "Unmount"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    # Unmount the disk image
    hdiutil detach "$DEV"
    if [ $? -eq 0 ]; then
        break
    fi
    if [ $i -eq 20 ]; then
        echo "Failed to unmount the disk image; exiting after 20 retries."
        exit 1
    fi
    echo "Failed to unmount the disk image; retrying in 30s"
    sleep 30
done

# Convert the disk image to read-only
hdiutil convert "${WORKING_DIRECTORY}/${DMGNAME}" -format UDBZ -o "${WORKING_DIRECTORY}/${COMPRESSEDDMGNAME}"

shasum -a 256 "${WORKING_DIRECTORY}/${COMPRESSEDDMGNAME}"

rm "${WORKING_DIRECTORY}/${DMGNAME}"
