#!/bin/bash
#
# Workaround for limitations of Xcode Previews
# for projects that have dynamic SPM libraries.
#
# $Id: //depot/HotReloading/fix_previews.sh#3 $
#

APP_ROOT="$CODESIGNING_FOLDER_PATH"
if [ -d "$APP_ROOT"/Contents ]; then
    APP_ROOT="$APP_ROOT"/Contents
fi

mkdir "$APP_ROOT"/Frameworks

for framework in "$CODESIGNING_FOLDER_PATH"/../PackageFrameworks/*; do
    cp -r "$framework" "$APP_ROOT"/Frameworks >>/tmp/fix_previews.txt 2>&1
done

exit 0
