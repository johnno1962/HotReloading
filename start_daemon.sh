#!/bin/bash
#
# Start up daemon process to rebuild changed sources
#
# $Id: //depot/HotReloading/start_daemon.sh#2 $
#

cd "$(dirname $0)"

LAST_LOG=`ls -t $SYMROOT/../../Logs/Build/*.xcactivitylog | head -n 1`

# kill any existing daemon process
kill -9 `ps auxww | grep debug/injectiond | grep -v grep | awk '{ print $2 }'`

# rebuild daemon
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin:/Library/Apple/usr/bin swift build &&

# run in background passing project file and list of directories to watch
(.build/debug/injectiond "$PROJECT_FILE_PATH" `gunzip <$LAST_LOG | tr '\r' '\n' | grep -e '  cd ' | sort -u | grep -v DerivedData | awk '{ print $2 }'` >/tmp/hot_reloading.log 2>&1 &)
