#!/bin/sh
# Start/stop the k3-weather display. Run from KUAL, or by hand over SSH:
#   sh /mnt/us/extensions/weather/bin/weather.sh start|stop
EXT=$(cd "$(dirname "$0")/.." && pwd)
PIDFILE=/tmp/k3-weather.pid
LOG="$EXT/weather.log"

LAT=42.3647
LON=-71.1042
NAME="Cambridge, MA"
UNITS=imperial
INTERVAL=1800
WIFI_SAVER=1
SLEEP=1
MBTA_INTERVAL=300
VIEW=mbta
QUIET_HOURS="02:00-04:30" # weather.conf can set QUIET_HOURS="" to turn it off
EXTRA_ARGS=
[ -f "$EXT/weather.conf" ] && . "$EXT/weather.conf"
[ "$WIFI_SAVER" = 1 ] && EXTRA_ARGS="$EXTRA_ARGS --wifi-saver"
[ "$SLEEP" = 1 ] && EXTRA_ARGS="$EXTRA_ARGS --sleep"

running() {
    [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null
}

case "$1" in
start)
    running && exit 0
    # Run the real work in the background, in its own session when the
    # Kindle's busybox has setsid. Launcher errors go to launch.log.
    echo "$(date '+%m-%d %H:%M:%S') weather.sh start" >>"$EXT/launch.log"
    if setsid true >/dev/null 2>&1; then
        setsid sh "$EXT/bin/weather.sh" run </dev/null >>"$EXT/launch.log" 2>&1 &
    else
        sh "$EXT/bin/weather.sh" run </dev/null >>"$EXT/launch.log" 2>&1 &
    fi
    ;;
run)
    trap '' HUP
    # Keep the device (and wifi) awake, and freeze the stock UI so it
    # doesn't paint over us or react to key presses.
    lipc-set-prop com.lab126.powerd preventScreenSaver 1
    lipc-set-prop com.lab126.wifid enable 1
    sleep 2 # let KUAL close its menu first
    killall -STOP cvm

    # MBTA rows contain spaces; pass each as one quoted argument.
    set --
    for m in "$MBTA1" "$MBTA2" "$MBTA3"; do
        [ -n "$m" ] && set -- "$@" --mbta "$m"
    done
    [ -n "$QUIET_HOURS" ] && set -- "$@" --quiet-hours "$QUIET_HOURS"

    # Keep logs across runs (one previous file), so a failed run is not lost
    # when the display is restarted.
    if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 200000 ]; then mv "$LOG" "$LOG.old"; fi
    echo "=== $(date) start (SLEEP=$SLEEP WIFI_SAVER=$WIFI_SAVER VIEW=$VIEW)" >>"$LOG"

    "$EXT/bin/k3-weather" --lat "$LAT" --lon "$LON" --name "$NAME" \
        --units "$UNITS" --interval "$INTERVAL" --battery-log "$EXT/battery.csv" \
        --mbta-interval "$MBTA_INTERVAL" --view "$VIEW" "$@" $EXTRA_ARGS >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    wait $!

    rm -f "$PIDFILE"
    killall -CONT cvm
    lipc-set-prop com.lab126.wifid enable 1
    lipc-set-prop com.lab126.powerd preventScreenSaver 0
    ;;
stop)
    running && kill "$(cat "$PIDFILE")"
    ;;
*)
    echo "usage: $0 start|stop" >&2
    exit 1
    ;;
esac
