#!/bin/bash -x
#
#  copy_bundle.sh
#  InjectionIII
#
#  Copies injection bundle for on-device injection.
#  Thanks @oryonatan
#
#  $Id: //depot/HotReloading/copy_bundle.sh#9 $
#

if [ "$CONFIGURATION" == "Debug" ]; then
    RESOURCES=${RESOURCES:-"$(dirname "$0")"}
    COPY="$CODESIGNING_FOLDER_PATH/iOSInjection.bundle"
    STRACE="$COPY/Frameworks/SwiftTrace.framework/SwiftTrace"
    PLIST="$COPY/Info.plist"
    if [ "$PLATFORM_NAME" == "macosx" ]; then
     BUNDLE=${1:-macOSInjection}
     COPY="$CODESIGNING_FOLDER_PATH/Contents/Resources/macOSInjection.bundle"
     STRACE="$COPY/Contents/Frameworks/SwiftTrace.framework/Versions/A/SwiftTrace"
     PLIST="$COPY/Contents/Info.plist"
    elif [ "$PLATFORM_NAME" == "appletvsimulator" ]; then
     BUNDLE=${1:-tvOSInjection}
    elif [ "$PLATFORM_NAME" == "xrsimulator" ]; then
     BUNDLE=${1:-xrOSInjection}
    elif [ "$PLATFORM_NAME" == "iphoneos" ]; then
     BUNDLE=${1:-maciOSInjection}
     rsync -a "$PLATFORM_DEVELOPER_LIBRARY_DIR"/{Frameworks,PrivateFrameworks}/XC* "$PLATFORM_DEVELOPER_USR_DIR/lib"/*.dylib "$COPY/Frameworks/" &&
     codesign -f --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp\=none --preserve-metadata\=identifier,entitlements,flags --generate-entitlement-der "$COPY/Frameworks"/{XC*,*.dylib};
    else
     BUNDLE=${1:-iOSInjection}
    fi
    rsync -a "$RESOURCES/$BUNDLE.bundle"/* "$COPY/" &&
    /usr/libexec/PlistBuddy -c "Add :UserHome string $HOME" "$PLIST" &&
    codesign -f --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp\=none --preserve-metadata\=identifier,entitlements,flags --generate-entitlement-der "$STRACE" "$COPY" &&
    defaults write com.johnholdsworth.InjectionIII "$PROJECT_FILE_PATH" $EXPANDED_CODE_SIGN_IDENTITY
fi
