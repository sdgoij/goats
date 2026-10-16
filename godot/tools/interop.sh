#!/usr/bin/env sh
#
# The scene against the shipping host, and against nothing at all.
#
#   godot/tools/interop.sh          # a modless probe joins a --no-mods host
#   godot/tools/interop.sh refuse   # the same probe is refused by a host requiring the repo's world mods
#   godot/tools/interop.sh herd     # the scene (presenting the repo's world mods) joins a host running them
#   godot/tools/interop.sh pair     # ...and *two* clients see each other's goat
#   godot/tools/interop.sh death    # ...and the mirrored herd is still moving after a client dies and respawns
#   godot/tools/interop.sh hostdeath # ...the same, hosted by *this* scene rather than by `goatsd`
#   godot/tools/interop.sh offline  # no server: the scene boots without a session
#   godot/tools/interop.sh shot     # ...and a window renders it, with the herd in it
#
# All seven are evidence. `join` proves the transport, the join handshake, the chat
# routing and the world datagrams work against the *shipping* binary, not just
# between two Godot peers. `refuse` proves the world-mod digest comparison
# (`APIv1.md` section 6.3) crosses two independent implementations -- the failure
# a player with the wrong mods actually sees. `herd` runs the real scene
# (`scenes/herd.tscn`) instead of a probe script, so it is the one that shows the
# core doing something with the wire rather than only reading it -- *and* it is
# where the digest **matches**: the scene presents the repository's own world set
# (`mods.world_mod_refs`) and the host requires exactly them, so the join is
# accepted and the flock travels. `pair` is the
# same scene twice against one host, which is the only way to see a *peer*: a
# `peer` frame is somebody else's goat, so one client can never produce one. And
# `offline` checks the thing a player hits first: pressing play with no session
# must leave them in a *world*, not in an error. `shot` is the one piece of
# evidence no gate can carry -- whether it *looks* like a world -- and it needs a
# window, so it is the one mode that is run by hand on a machine with a GPU.
#
# `hostdeath` is `death` with the host changed: there is no `goatsd` in it at all,
# and the ticket the joiner is given is the *scene's* own. That is the only way to
# ask the question the report was about -- whether a **Godot host** keeps
# publishing a herd that moves while a client dies -- because a `goatsd` session
# can only ever show what this end mirrors. It runs two things
# (`verify_herd_host.gd` hosting, `verify_herd_death.gd` joining and dying) and
# reads both.
#
# Overrides: GODOT_BIN (the engine), GOATSD_BIN (the server).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
godot_dir=$root/godot
log=$root/target/interop-goatsd.log

mode=${1:-join}
case "$mode" in
    join|refuse|herd|pair|death|hostdeath|offline|shot) ;;
    *)
        echo "interop.sh: unknown mode '$mode' (want join, refuse, herd, pair, death, hostdeath, offline or shot)" >&2
        exit 2
        ;;
esac

# Godot is a native Windows binary here, so it wants a native path; the server is
# launched by the shell, which wants the shell's. Convert only where needed.
to_native() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$1"
    else
        printf '%s' "$1"
    fi
}

godot_bin=${GODOT_BIN:-/c/Users/T/bin/Godot_v4.7.2-stable_win64.exe}
if [ ! -x "$godot_bin" ]; then
    echo "interop.sh: $godot_bin is not executable; set GODOT_BIN" >&2
    exit 1
fi

# `offline` is the one mode with no server behind it.
if [ "$mode" = "offline" ]; then
    offline_log=$root/target/interop-offline.log
    : > "$offline_log"
    set +e
    # 20 seconds is long enough to boot the scene and long enough that a scene
    # which *quits* has clearly quit; the timeout killing it is the pass.
    timeout 20 "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        > "$offline_log" 2>&1
    status=$?
    set -e
    if [ "$status" -ne 124 ]; then
        echo "interop.sh: the scene exited ($status) instead of running offline. Its output:" >&2
        grep -vE "^$|Godot Engine|Initialize godot-rust" "$offline_log" >&2
        exit 1
    fi
    if ! grep -q "offline: no GOATSD_TICKET" "$offline_log"; then
        echo "interop.sh: the scene ran, but never said it was offline. Its output:" >&2
        grep -vE "^$|Godot Engine|Initialize godot-rust" "$offline_log" >&2
        exit 1
    fi
    # A scene that *runs* is not necessarily a scene that works: this gate passed
    # once while `_process` failed on a null node every frame -- 60 errors a second,
    # invisible to a check that only asks whether the process is still alive. The
    # same trap the `.tscn` note below describes, so the log is read for it.
    if grep -q "SCRIPT ERROR" "$offline_log"; then
        echo "interop.sh: the scene ran, but with script errors. Its output:" >&2
        grep -vE "^$|Godot Engine|Initialize godot-rust" "$offline_log" >&2
        exit 1
    fi
    echo "interop.sh: the scene boots and runs with no session at all"
    exit 0
fi

# `hostdeath` is the one mode whose host is the port itself, so there is no `goatsd`
# to start and no server ticket to wait for: the ticket the joiner is given comes
# out of the hosting probe. Both processes are read afterwards, because the report
# is about a *client's* view of a *host's* herd, and either end failing is the bug.
if [ "$mode" = "hostdeath" ]; then
    host_log=$root/target/host-herd.log
    join_log=$root/target/join-herd.log
    : > "$host_log"
    : > "$join_log"
    "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_herd_host.gd > "$host_log" 2>&1 &
    host_pid=$!

    # The host probe prints its ticket raw on a line of its own, once it is up.
    attempts=0
    ticket=
    while [ "$attempts" -lt 240 ]; do
        ticket=$(sed -n 's/^ticket //p' "$host_log" | sed -n '1p')
        if [ -n "$ticket" ]; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 0.25
    done
    if [ -z "$ticket" ]; then
        kill "$host_pid" 2>/dev/null || true
        echo "interop.sh: the hosting probe never printed a ticket. Its output:" >&2
        grep -vE "^$|Godot Engine|Initialize godot-rust" "$host_log" >&2
        exit 1
    fi
    echo "interop.sh: this scene is hosting (${mode} mode)"

    set +e
    GOATSD_TICKET="$ticket" "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_herd_death.gd > "$join_log" 2>&1
    join_status=$?
    wait "$host_pid"
    host_status=$?
    set -e

    # Both ends are read, not only the exit codes: which end stopped is the first
    # thing worth knowing, and a host that stopped *publishing* looks identical to
    # a client that stopped applying it from the outside.
    grep -E "^(OK|FAIL|peer|before|after|motion|publishing)" "$host_log" || true
    grep -E "^(OK|FAIL|herd|before|dead|after|motion)" "$join_log" || true
    if [ "$host_status" -ne 0 ] || [ "$join_status" -ne 0 ]; then
        exit 1
    fi
    echo "interop.sh: a Godot host's herd keeps moving through a client's death and respawn"
    exit 0
fi

# Which world-mod set `goatsd` requires. `join` and `refuse` run a bare
# `verify_interop.gd` probe with no `ModHost` behind it, so it presents *nothing*:
# `join` gives it a host that requires nothing (`--no-mods`), and `refuse` a host
# that requires the repository's world mods -- the digest refusal. `herd`, `pair`
# and `shot` run the real *scene*, which presents the repository's own set
# (`mods.world_mod_refs`), so the host runs the same mods and the join is accepted.
case "$mode" in
    join) mods_flag=--no-mods ;;
    herd|pair|shot|death|refuse) mods_flag= ;;
esac

server=${GOATSD_BIN:-$root/target/release/goatsd.exe}
if [ ! -x "$server" ]; then
    echo "interop.sh: $server is not built; run:" >&2
    echo "    cargo build --release -p server" >&2
    exit 1
fi

# goatsd resolves `mods/` from the working directory, so start it at the root.
cd "$root"
: > "$log"
"$server" godot-host $mods_flag > "$log" 2>&1 &
server_pid=$!

cleanup() {
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# The ticket is the whole interface; wait for goatsd to print it.
attempts=0
ticket=
while [ "$attempts" -lt 120 ]; do
    ticket=$(sed -n 's/^ticket //p' "$log" | sed -n '1p')
    if [ -n "$ticket" ]; then
        break
    fi
    attempts=$((attempts + 1))
    sleep 0.25
done

if [ -z "$ticket" ]; then
    echo "interop.sh: goatsd never printed a ticket. Its log:" >&2
    cat "$log" >&2
    exit 1
fi
echo "interop.sh: goatsd up as godot-host (${mode} mode)"

set +e
if [ "$mode" = "pair" ]; then
    # The same scene twice against one host. Both ends publish their own goat, the
    # server relays each to the other, and each end's mirror either places a goat
    # or does not -- which is the whole of M21 proved end to end, and the one thing
    # a single client cannot show.
    a=$root/target/peers-a.log
    b=$root/target/peers-b.log
    : > "$a"
    : > "$b"
    GOATSD_TICKET="$ticket" "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_peers_live.gd > "$a" 2>&1 &
    pid_a=$!
    GOATSD_TICKET="$ticket" "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_peers_live.gd > "$b" 2>&1 &
    pid_b=$!
    wait "$pid_a"
    status_a=$?
    wait "$pid_b"
    status_b=$?
    status=0
    if [ "$status_a" -ne 0 ] || [ "$status_b" -ne 0 ]; then
        status=1
    fi
    # Both ends are read, not only the exit codes: a client that never saw a peer
    # says so, and which one failed is the first thing worth knowing.
    grep -E "^(OK|FAIL|peers:)" "$a" || true
    grep -E "^(OK|FAIL|peers:)" "$b" || true
elif [ "$mode" = "herd" ]; then
    # The real scene, with the probe switched on: it settles, reports and exits.
    GOATSD_TICKET="$ticket" GOATS_PROBE=1 \
        "$godot_bin" --headless --path "$(to_native "$godot_dir")"
    status=$?
elif [ "$mode" = "death" ]; then
    # The real scene, and the probe that kills and respawns its own goat: what a client's *own*
    # death has to leave alone is the herd it mirrors, which is the host's.
    GOATSD_TICKET="$ticket" "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_herd_death.gd
    status=$?
elif [ "$mode" = "shot" ]; then
    # The real scene, in a window, long enough for a populated world to arrive and
    # for the herd to ease onto the ground under it. See `tools/screenshot.gd`.
    GOATSD_TICKET="$ticket" GOATS_SHOT_FRAMES=${GOATS_SHOT_FRAMES:-600} \
        "$godot_bin" --path "$(to_native "$godot_dir")" \
        --script res://tools/screenshot.gd --resolution ${GOATS_SHOT_RESOLUTION:-1280x720}
    status=$?
    echo "interop.sh: wrote $godot_dir/shot.png"
else
    GOATSD_TICKET="$ticket" GOATSD_EXPECT="$mode" \
        "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_interop.gd
    status=$?
fi
set -e

echo "---- goatsd said ----"
# The session's own view: joins, leaves, the roster and chat.
grep -E "world mods|world set|joined|left|roster|chat|\[net\]" "$log" || true

exit "$status"
