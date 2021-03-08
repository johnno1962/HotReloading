#!/bin/bash
#
# Workaround for limitations of Xcode Previews
# for projects that have dynamic SPM libraries.
#
# $Id: //depot/HotReloading/fix_previews.sh#1 $
#

mkdir "$CODESIGNING_FOLDER_PATH"/Frameworks
for framework in "$CODESIGNING_FOLDER_PATH"/../PackageFrameworks/*; do
    cp -r "$framework" "$CODESIGNING_FOLDER_PATH"/Frameworks >>/tmp/fix_previews.txt 2>&1
done

exit 0
