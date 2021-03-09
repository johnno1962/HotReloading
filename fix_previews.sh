#!/bin/bash
#
#  Workaround for limitations of Xcode Previews
#  for projects that have dynamic SPM libraries.
#  Running this script seems to help Xcode not
#  leave out frameworks when running previews.
#
#  $Id: //depot/HotReloading/fix_previews.sh#5 $
#

APP_ROOT="$CODESIGNING_FOLDER_PATH"
if [ -d "$APP_ROOT"/Contents ]; then
    APP_ROOT="$APP_ROOT"/Contents
fi

mkdir "$APP_ROOT"/Frameworks

for framework in "$CODESIGNING_FOLDER_PATH"/../PackageFrameworks/*.framework; do
    cp -r "$framework" "$APP_ROOT"/Frameworks >>/tmp/fix_previews.txt 2>&1
done

exit 0
