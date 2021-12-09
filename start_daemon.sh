#!/bin/bash -x
#
# Start up daemon process to rebuild changed sources
#
# $Id: //depot/HotReloading/start_daemon.sh#32 $
#

cd "$(dirname "$0")"

if [ "$CONFIGURATION" = "Release" ]; then
    echo "error: You shouldn't be shipping HotReloading in your app!"
    exit 1
fi

if [ -f "/tmp/injecting_storyboard.txt" ]; then
    rm /tmp/injecting_storyboard.txt
    exit 0
fi


DERIVED_DATA="$(dirname $(dirname $SYMROOT))"
export DERIVED_LOGS="$DERIVED_DATA/Logs/Build"

LAST_LOG=`ls -t $DERIVED_LOGS/*.xcactivitylog | head -n 1`

export NORMAL_ARCH_FILE="$OBJECT_FILE_DIR_normal/$ARCHS/$PRODUCT_NAME"
export LINK_FILE_LIST="$NORMAL_ARCH_FILE.LinkFileList"

# kill any existing daemon process
kill -9 `ps auxww | grep .build/debug/injectiond | grep -v grep | awk '{ print $2 }'`

# Avoid having to fetch dependancies again
# mkdir -p .build; ln -s "$DERIVED_DATA"/SourcePackages/repositories .build

# rebuild daemon
/usr/bin/env -i PATH="$PATH" /usr/bin/swift build --product injectiond &&

# clone Contents directory for Cocoa
rsync -at Contents .build/debug &&

# run in background passing project file, logs directory
# followed by a list of additional directories to watch.
(.build/debug/injectiond "$PROJECT_FILE_PATH" "$DERIVED_LOGS" `gunzip <$LAST_LOG | tr '\r' '\n' | grep -e '  cd ' | sort -u | grep -v DerivedData | grep -v grep | awk '{ print $2 }'` >/tmp/hot_reloading.log 2>&1 &)
