#!/bin/sh
# Find out whether this Kindle can suspend and wake itself on a timer.
#
# Run with the weather display stopped and the USB cable UNPLUGGED (the
# Kindle won't really suspend on USB power). Takes up to ~20 minutes and
# prints "sleeptest: DONE" at the top of the screen when finished. Results
# go to sleeptest.log next to weather.conf.
#
# Both tests put the Kindle into its screensaver (as if you pressed the power
# switch), let powerd suspend it, and ask for a wake-up after $WAIT seconds.
# If the Kindle is still in the screensaver ~5 minutes into a test, the timer
# didn't wake it: slide the power switch and the script carries on (the log
# records how long it slept, which tells us it was you and not the timer).
#
# Written for the K3's BusyBox 1.7.2: no grep -E, use head/tail -n.
# NB: powerd_test's flags are actions, not options (-h = hold the power
# button = shutdown prompt). Only -p (press) is used here.
EXT=$(cd "$(dirname "$0")/.." && pwd)
LOG="$EXT/sleeptest.log"
WAIT=90
RTC=/sys/class/rtc/rtc0 # pmic_rtc: the one with a wakealarm

log() { echo "$(date '+%H:%M:%S') $*" >>"$LOG"; }
run() {
    log "\$ $*"
    sh -c "$*" >>"$LOG" 2>&1
    log "  -> exit $?"
}
# Show progress on screen as well as in the log.
say() {
    log "$*"
    eips 1 1 "sleeptest: $*                    " >/dev/null 2>&1
}
# Hardware clock seconds: keeps counting through suspend.
rtcnow() { cat $RTC/since_epoch 2>/dev/null || date +%s; }
pstate() { lipc-get-prop com.lab126.powerd state 2>&1; }

# Poll until powerd says it is ready to suspend, logging state changes.
wait_ready() {
    log "waiting for powerd 'ready to suspend' (up to 240s)"
    t0=$(rtcnow)
    prev=
    while [ $(($(rtcnow) - t0)) -lt 240 ]; do
        st=$(pstate)
        if [ "$st" != "$prev" ]; then
            log "state: $st"
            prev=$st
        fi
        case "$st$(lipc-get-prop com.lab126.powerd status 2>&1)" in
        *[Rr]eady*) return 0 ;;
        esac
        sleep 1
    done
    log "never became ready"
    return 1
}

# Wait for a jump in the hardware clock, meaning we were suspended.
wait_suspend() {
    t0=$(rtcnow)
    last=$t0
    while [ $((last - t0)) -lt 360 ]; do
        sleep 1
        t=$(rtcnow)
        if [ $((t - last)) -gt 5 ]; then
            log "SUSPENDED for ~$((t - last))s, back $((t - t0))s after arming. ~${WAIT}s = timer woke it; much longer = woken by hand"
            return
        fi
        last=$t
    done
    log "never suspended within 6 min"
}

# $1 = label, $2 = command that arms the wake-up
sleep_test() {
    say "$1"
    run "lipc-set-prop com.lab126.powerd preventScreenSaver 0"
    st=$(pstate)
    log "state before: $st"
    case "$st" in
    active) run "powerd_test -p" ;; # power-button press: go to screensaver
    *) log "not active; not pressing the button" ;;
    esac
    wait_ready && run "$2"
    wait_suspend
    run "lipc-get-prop com.lab126.powerd state"
    run "cat /proc/driver/rtc"
    # leave the screensaver
    [ "$(pstate)" = active ] || run "powerd_test -p"
    sleep 20
}

main() {
    : >"$LOG"
    if [ -f /tmp/k3-weather.pid ] && kill -0 "$(cat /tmp/k3-weather.pid)" 2>/dev/null; then
        log "weather display is running; stop it first"
        return
    fi

    log "== info (v3)"
    run "cat /proc/uptime; date"
    run "lipc-get-prop com.lab126.powerd status"
    run "dmesg | tail -n 40"

    # Log every powerd event with a timestamp while the tests run.
    (lipc-wait-event -m com.lab126.powerd '*' 2>&1 | while read -r ev; do log "event: $ev"; done) &
    events=$!

    sleep_test "B1 powerd rtcWakeup" \
        "lipc-set-prop -i com.lab126.powerd rtcWakeup $WAIT"
    sleep_test "B2 rtc0 wakealarm" \
        "echo 0 > $RTC/wakealarm; echo \$((\$(cat $RTC/since_epoch) + $WAIT)) > $RTC/wakealarm; cat /proc/driver/rtc"

    kill $events 2>/dev/null
    killall lipc-wait-event 2>/dev/null
    run "dmesg | tail -n 60"
    say "DONE - plug in USB and send sleeptest.log"
}

# KUAL kills what it launched when its menu closes, so re-launch ourselves
# in a new session and log (but survive) any hangup/terminate signals.
if [ "$1" != detached ]; then
    echo "$(date '+%m-%d %H:%M:%S') sleeptest.sh start" >>"$EXT/launch.log"
    if setsid true >/dev/null 2>&1; then
        setsid sh "$EXT/bin/sleeptest.sh" detached </dev/null >>"$EXT/launch.log" 2>&1 &
    else
        sh "$EXT/bin/sleeptest.sh" detached </dev/null >>"$EXT/launch.log" 2>&1 &
    fi
    exit 0
fi
trap 'log "got SIGHUP, ignoring"' HUP
trap 'log "got SIGTERM, ignoring"' TERM
main
