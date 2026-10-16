#!/usr/bin/env sh
#
# Run every standalone gate and print a one-line verdict each.
#
#   godot/tools/gates.sh              # every gate that needs no server
#   GODOT_BIN=... godot/tools/gates.sh
#
# A gate is a `SceneTree` script that quits non-zero on failure and prints `FAIL: ...` lines with
# the reason (and `OK: ...` when it has none), so this is a loop rather than a list: a new
# `tools/verify_*.gd` is picked up by existing. The list it *cannot* discover is the five that need
# a session behind them -- a probe that waits for a herd from a server nobody started hangs instead
# of failing -- and those are `interop.sh`'s, which starts the server and hands out the ticket:
#
#   verify_interop.gd         interop.sh join | refuse
#   verify_peers_live.gd      interop.sh pair
#   verify_herd_death.gd      interop.sh death | hostdeath
#   verify_herd_host.gd       interop.sh hostdeath   (the *host* half of the same question)
#   verify_host_reference.gd  interop.sh jsjoin      (the *host* the reference client joins)
#
# Each gate gets `TIMEOUT` seconds, which is not a formality: a GDScript file that fails to compile
# can make Godot *loop* rather than error, with no output at all, so a gate that never returns
# looks exactly like one that is thinking.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
godot_dir=$root/godot
godot_bin=${GODOT_BIN:-/c/Users/T/bin/Godot_v4.7.2-stable_win64.exe}
timeout_secs=${GATE_TIMEOUT:-300}
log_dir=$root/target/gate-logs

# The session gates, by name: see the header. Kept as a `case` so the reason sits beside it.
session_gate() {
    case "$1" in
        verify_interop|verify_peers_live|verify_herd_death|verify_herd_host|verify_host_reference) return 0 ;;
        *) return 1 ;;
    esac
}

if [ ! -x "$godot_bin" ]; then
    echo "gates.sh: $godot_bin is not executable; set GODOT_BIN" >&2
    exit 1
fi

mkdir -p "$log_dir"

gates=$(ls "$here"/verify_*.gd | sed 's|.*/||; s|\.gd$||' | sort)
failed=""
total=0
for gate in $gates; do
    if session_gate "$gate"; then
        continue
    fi
    total=$((total + 1))
    log=$log_dir/$gate.log
    set +e
    timeout "$timeout_secs" "$godot_bin" --headless --path "$godot_dir" \
        --script "res://tools/$gate.gd" > "$log" 2>&1
    status=$?
    set -e
    verdict=$(grep -E "^(OK|FAIL)" "$log" | tail -n 1)
    if [ "$status" -eq 0 ]; then
        printf 'PASS %-24s %s\n' "$gate" "$verdict"
    else
        printf 'FAIL %-24s (exit %s) %s\n' "$gate" "$status" "$verdict"
        failed="$failed $gate"
    fi
done

if [ -n "$failed" ]; then
    echo "FAILED:$failed"
    echo "logs: $log_dir"
    exit 1
fi
echo "all $total gates green (the five session gates are interop.sh's)"
