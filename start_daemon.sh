#!/bin/bash
#
# Start up daemon process to rebuild changed sources
#
# $Id: //depot/HotReloading/start_daemon.sh#19 $
#

cd "$(dirname $0)"

if [ "$CONFIGURATION" = "Release" ]; then
    echo "error: You shouldn't be shipping HotReloading in your app!"
    exit 1
fi

if [ -f "/tmp/injecting_storyboard.txt" ]; then
    rm /tmp/injecting_storyboard.txt
    exit 0
fi

DERIVED_LOGS="$(dirname $(dirname $SYMROOT))/Logs/Build"

LAST_LOG=`ls -t $DERIVED_LOGS/*.xcactivitylog | head -n 1`

export NORMAL_ARCH_FILE="$OBJECT_FILE_DIR_normal/$ARCHS/$PRODUCT_NAME"
export LINK_FILE_LIST="$NORMAL_ARCH_FILE.LinkFileList"

# kill any existing daemon process
kill -9 `ps auxww | grep .build/debug/injectiond | grep -v grep | awk '{ print $2 }'`

# rebuild daemon
/usr/bin/env -i PATH="$PATH" "$TOOLCHAIN_DIR"/usr/bin/swift build &&

# provide a Contents driectory for Cocoa
rm -f .build/debug/Contents && ln -s "$PWD/Contents" .build/debug &&

# run in background passing project file, logs directory
# followed by a list of additional directories to watch.
(.build/debug/injectiond "$PROJECT_FILE_PATH" "$DERIVED_LOGS" `gunzip <$LAST_LOG | tr '\r' '\n' | grep -e '  cd ' | sort -u | grep -v DerivedData | awk '{ print $2 }'` >/tmp/hot_reloading.log 2>&1 &)
