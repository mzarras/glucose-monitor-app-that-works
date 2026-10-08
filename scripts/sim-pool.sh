#!/usr/bin/env bash
# Machine-wide build slots and the pooled test simulators (D60). scripts/check.sh sources this file
# for its functions; run it directly to inspect or clean up:
#
#   scripts/sim-pool.sh status              build slots (who holds each) and the pool simulators
#   scripts/sim-pool.sh shutdown [--force]  shut down every booted pool simulator
#   scripts/sim-pool.sh delete [--force]    shut down and delete the pool simulators, drop stale slots
#
# Without --force, shutdown and delete leave alone a simulator whose slot a live check.sh holds.
#
# Build slots. check.sh holds one of CHECK_SLOTS (default 2) slots for its whole run, so at most two
# build-heavy runs share the Mac. Slot <n> is the directory ~/Library/Caches/sensor-check/slots/<n>,
# taken with mkdir (atomic; no flock on macOS) and holding the files pid, start-time (the holder's
# `ps -o lstart=`), worktree, since (epoch seconds) and info. The path is per user and fixed, not
# under $TMPDIR, because agents may run with different TMPDIRs. A slot is stale when its pid is dead
# (`kill -0`) or reused (the process now under that pid started at another time); a waiting run
# takes a stale slot over.
#
# Pool simulators. Slot <n> runs its simulator gates on sensor-check-<n> (iPhone 17, the newest
# installed iOS 26.x runtime), created on first use and reused; CHECK_SLOTS=0 runs use
# sensor-check-0. check.sh boots it for the run and shuts it down at exit (docs/gates.md).
#
# Bash 3.2 (macOS /bin/bash), BSD userland.

SENSOR_CHECK_HOME="$HOME/Library/Caches/sensor-check"
SLOT_ROOT="$SENSOR_CHECK_HOME/slots"
POOL_PREFIX="sensor-check-"
POOL_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17"
POOL_RUNTIME_MAJOR=26

# ---------------------------------------------------------------------------------------------
# Build slots
# ---------------------------------------------------------------------------------------------

# Start time of process $1 as `ps` prints it ("Thu Oct  8 17:02:11 2026"); empty if none.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//; s/ *$//'; }

# Succeeds if slot directory $1 exists and its holder is gone: the pid is dead (`kill -0` fails and
# `ps` has no such process; kill -0 alone also fails on another user's live process), or it was
# reused (the process now under that pid started at another time). A slot without a pid file is
# being taken (the pid file is written last); it counts as stale only after 60 s.
slot_stale() {
    local d="$1" pid mtime started
    [ -d "$d" ] || return 1
    pid="$(cat "$d/pid" 2>/dev/null)"
    if [ -z "$pid" ]; then
        mtime="$(stat -f %m "$d" 2>/dev/null)" || return 1
        [ $(( $(date +%s) - mtime )) -gt 60 ]
        return
    fi
    started="$(proc_start "$pid")"
    if ! kill -0 "$pid" 2>/dev/null && [ -z "$started" ]; then return 0; fi
    [ "$started" != "$(cat "$d/start-time" 2>/dev/null)" ]
}

# Removes slot directory $1 if it is stale. Breakers are serialised by the mkdir lock .break and
# re-check staleness inside it, so two waiters can't both break a slot and then both hold it.
slot_break_if_stale() {
    local d="$1" mtime rc=1
    if ! mkdir "$SLOT_ROOT/.break" 2>/dev/null; then
        # A breaker that died inside this tiny section leaves .break behind; drop it after 60 s.
        mtime="$(stat -f %m "$SLOT_ROOT/.break" 2>/dev/null)"
        if [ -n "$mtime" ] && [ $(( $(date +%s) - mtime )) -gt 60 ]; then rm -rf "$SLOT_ROOT/.break"; fi
        return 1
    fi
    if slot_stale "$d"; then rm -rf "$d"; rc=0; fi
    rmdir "$SLOT_ROOT/.break" 2>/dev/null
    return $rc
}

# Tries to take slot $1 for this process ($$), recording $2 as what the run is doing.
slot_try() {
    local n="$1" info="$2" d="$SLOT_ROOT/$1"
    if ! mkdir "$d" 2>/dev/null; then
        slot_break_if_stale "$d" || return 1
        mkdir "$d" 2>/dev/null || return 1
    fi
    proc_start "$$" > "$d/start-time"
    printf '%s\n' "$ROOT" > "$d/worktree"
    date +%s > "$d/since"
    printf '%s\n' "$info" > "$d/info"
    printf '%s\n' "$$" > "$d/pid.tmp" && mv "$d/pid.tmp" "$d/pid"
}

# One line per slot 1..$1 (and any other slot directory present): who holds it.
slot_describe() {
    local n="$1" d="$SLOT_ROOT/$1" pid since info wt mins state
    if [ ! -d "$d" ]; then echo "slot $n: free"; return; fi
    pid="$(cat "$d/pid" 2>/dev/null)"
    since="$(cat "$d/since" 2>/dev/null)"
    info="$(cat "$d/info" 2>/dev/null)"
    wt="$(cat "$d/worktree" 2>/dev/null)"
    mins="?"
    [ -n "$since" ] && mins=$(( ($(date +%s) - since) / 60 ))
    state="alive"
    slot_stale "$d" && state="STALE"
    echo "slot $n: pid ${pid:-?} ($state), ${wt##*/}, $info, for $mins min"
}

slots_describe() {
    local max="$1" n=1 d
    while [ "$n" -le "$max" ]; do slot_describe "$n"; n=$((n + 1)); done
    for n in $(ls "$SLOT_ROOT" 2>/dev/null | grep -E '^[0-9]+$' | sort -n); do
        [ "$n" -gt "$max" ] && slot_describe "$n"
    done
}

# Waits for one of slots 1..$1 and sets SLOT. Prints who holds the slots every ~30 s while waiting.
slot_acquire() {
    local max="$1" info="$2" n start now last=0
    mkdir -p "$SLOT_ROOT" || return 1
    start="$(date +%s)"
    while :; do
        n=1
        while [ "$n" -le "$max" ]; do
            if slot_try "$n" "$info"; then
                SLOT="$n"
                SLOT_WAITED=$(( $(date +%s) - start ))
                return 0
            fi
            n=$((n + 1))
        done
        now="$(date +%s)"
        if [ "$last" -eq 0 ] || [ $((now - last)) -ge 30 ]; then
            echo "check.sh: waiting for a build slot (CHECK_SLOTS=$max, waited $((now - start)) s):"
            slots_describe "$max" | sed 's/^/    /'
            last="$now"
        fi
        sleep 5
    done
}

# Releases this process's slot (only if the slot still names this process).
slot_release() {
    [ -n "${SLOT:-}" ] || return 0
    local d="$SLOT_ROOT/$SLOT"
    if [ "$(cat "$d/pid" 2>/dev/null)" = "$$" ]; then rm -rf "$d"; fi
    SLOT=""
}

# Succeeds if slot $1 is held by a live process.
slot_held() { [ -d "$SLOT_ROOT/$1" ] && ! slot_stale "$SLOT_ROOT/$1"; }

# ---------------------------------------------------------------------------------------------
# Pool simulators
# ---------------------------------------------------------------------------------------------

# Newest available iOS 26.x runtime as "iOS 26.2|com.apple.CoreSimulator.SimRuntime.iOS-26-2".
pool_runtime() {
    xcrun simctl list runtimes 2>/dev/null | awk -v major="$POOL_RUNTIME_MAJOR" '
        $1 == "iOS" && index($2, major ".") == 1 && $0 !~ /unavailable/ {
            split($2, v, ".")
            key = v[2] * 1000 + v[3]
            if (best == "" || key > bestkey) { best = "iOS " $2 "|" $NF; bestkey = key }
        }
        END { if (best != "") print best }'
}

# Every pool device, one per line: "name|udid|state|runtime section" (e.g. "...|Booted|iOS 26.2").
pool_devices() {
    xcrun simctl list devices 2>/dev/null | awk -v prefix="$POOL_PREFIX" '
        /^-- / { rt = $0; sub(/^-- /, "", rt); sub(/ --$/, "", rt); next }
        {
            line = $0; sub(/^[[:space:]]+/, "", line)
            if (index(line, prefix) != 1) next
            if (!match(line, / \([0-9A-F-]+\) \(/)) next
            name = substr(line, 1, RSTART - 1)
            udid = substr(line, RSTART + 2, RLENGTH - 5)
            state = substr(line, RSTART + RLENGTH); sub(/\).*/, "", state)
            print name "|" udid "|" state "|" rt
        }'
}

# Sets POOL_UDID to sensor-check-$1 on the newest iOS 26.x runtime, creating it if needed
# (POOL_CREATED=1). A pool device of that name on another runtime is ours and out of date: deleted.
pool_sim_ensure() {
    local name="$POOL_PREFIX$1" rt rt_name rt_id dname dudid dstate drt out
    POOL_UDID=""; POOL_CREATED=0
    rt="$(pool_runtime)"
    if [ -z "$rt" ]; then echo "no iOS $POOL_RUNTIME_MAJOR.x simulator runtime is installed" >&2; return 1; fi
    rt_name="${rt%%|*}"; rt_id="${rt#*|}"
    while IFS='|' read -r dname dudid dstate drt; do
        [ "$dname" = "$name" ] || continue
        if [ "$drt" = "$rt_name" ] && [ -z "$POOL_UDID" ]; then
            POOL_UDID="$dudid"
        else
            echo "deleting $name $dudid ($drt): not on $rt_name, or a duplicate"
            xcrun simctl shutdown "$dudid" >/dev/null 2>&1
            xcrun simctl delete "$dudid" || return 1
        fi
    done <<EOF
$(pool_devices)
EOF
    if [ -z "$POOL_UDID" ]; then
        out="$(xcrun simctl create "$name" "$POOL_DEVICE_TYPE" "$rt_id" 2>&1)" || { echo "simctl create $name: $out" >&2; return 1; }
        POOL_UDID="$out"; POOL_CREATED=1
        echo "created $name $POOL_UDID ($rt_name)"
    fi
}

# State of device $1 ("Booted", "Shutdown", ...).
pool_state() {
    xcrun simctl list devices 2>/dev/null | grep -F "($1)" | sed -E 's/.*\) \(([^)]*)\).*/\1/' | head -n 1
}

# Bundle ids of the user-installed apps on booted device $1 (`simctl listapps` prints an old-style
# plist: a top-level dictionary keyed by bundle id, each entry with ApplicationType = User|System).
pool_user_apps() {
    xcrun simctl listapps "$1" 2>/dev/null | awk '
        /^    "[^"]+" = / { id = $1; gsub(/"/, "", id); next }
        /^    [A-Za-z0-9._-]+ = +[{]/ { id = $1; next }
        /^        ApplicationType = User;/ { print id }'
}

# ---------------------------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------------------------

pool_main() {
    local cmd="${1:-status}" force=0 dname dudid dstate drt idx d
    [ "${2:-}" = "--force" ] && force=1
    case "$cmd" in
        status)
            echo "Build slots ($SLOT_ROOT):"
            slots_describe "${CHECK_SLOTS:-2}" | sed 's/^/  /'
            echo "Pool simulators (iPhone 17, newest iOS $POOL_RUNTIME_MAJOR.x: $(pool_runtime | sed 's/|.*//')):"
            pool_devices | awk -F'|' '{ printf "  %-16s %s  %-9s %s\n", $1, $2, $3, $4 } END { if (NR == 0) print "  (none yet; check.sh creates them on first use)" }'
            ;;
        shutdown|delete)
            while IFS='|' read -r dname dudid dstate drt; do
                [ -n "$dname" ] || continue
                idx="${dname#$POOL_PREFIX}"
                if [ "$force" -eq 0 ] && slot_held "$idx"; then
                    echo "skipped $dname: $(slot_describe "$idx") (--force to override)"
                    continue
                fi
                if [ "$dstate" != "Shutdown" ]; then
                    xcrun simctl shutdown "$dudid" && echo "shut down $dname ($dudid)"
                fi
                if [ "$cmd" = delete ]; then xcrun simctl delete "$dudid" && echo "deleted $dname ($dudid)"; fi
            done <<EOF
$(pool_devices)
EOF
            if [ "$cmd" = delete ]; then
                for d in "$SLOT_ROOT"/*; do
                    [ -d "$d" ] || continue
                    if slot_stale "$d"; then rm -rf "$d" && echo "removed stale slot ${d##*/}"; fi
                done
            fi
            ;;
        *)
            echo "usage: scripts/sim-pool.sh status | shutdown [--force] | delete [--force]" >&2
            return 2
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -uo pipefail
    ROOT="$(cd "$(dirname "$0")/.." && pwd)"
    pool_main "$@"
    exit $?
fi
