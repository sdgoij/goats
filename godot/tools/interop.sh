#!/usr/bin/env sh
#
# The scene against the shipping host, and against nothing at all.
#
#   godot/tools/interop.sh          # a modless probe joins a --no-mods host
#   godot/tools/interop.sh refuse   # the same probe is refused by a host requiring the repo's world mods
#   godot/tools/interop.sh pull     # ...and with --pull it fetches them, installs them and joins
#   godot/tools/interop.sh herd     # the scene (presenting the repo's world mods) joins a host running them
#   godot/tools/interop.sh pair     # ...and *two* clients see each other's goat
#   godot/tools/interop.sh death    # ...and the mirrored herd is still moving after a client dies and respawns
#   godot/tools/interop.sh hostdeath # ...the same, hosted by *this* scene rather than by `goatsd`
#   godot/tools/interop.sh jsjoin   # the *reference* client joins this scene hosting (needs a window)
#   godot/tools/interop.sh offline  # no server: the scene boots without a session
#   godot/tools/interop.sh shot     # ...and a window renders it, with the herd in it
#
# All nine are evidence. `join` proves the transport, the join handshake, the chat
# routing and the world datagrams work against the *shipping* binary, not just
# between two Godot peers. `refuse` proves the world-mod digest comparison
# (`APIv1.md` section 6.3) crosses two independent implementations -- the failure
# a player with the wrong mods actually sees. `pull` is the other side of the same
# refusal (M18d): the *same* host and the *same* modless probe, but with the fetch
# consented to, so the probe asks the host what it runs, has `crates/pull` verify
# and install the archive, and joins on the retry -- the last multiplayer gap, and
# the one thing neither a Godot peer nor a unit test can show, because the archive
# has to come off the wire and hash to the host's digest. `herd` runs the real scene
# (`scenes/herd.tscn`) instead of a probe script, so it is the one that shows the
# core doing something with the wire rather than only reading it -- *and* it is
# where the digest **matches**: the scene presents the repository's own world set
# (`mods.world_mod_refs`) and the host requires exactly them, so the join is
# accepted and the flock travels. `pair` is the
# same scene twice against one host, which is the only way to see a *peer*: a
# `peer` frame is somebody else's goat, so one client can never produce one. Each
# end also takes off halfway through (`GOATSD_TICKET`'s pair and the flight slice),
# so the *fly* gait and its pitch/roll are what the other end mirrors. And
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
# `jsjoin` is the one mode whose *joiner* is not a Godot peer: it is the reference
# (raylib/JavaScript) client, the other implementation of the same protocol, which
# `interop.sh` never otherwise pairs with *this scene's own host*. Every other mode is
# Godot with Godot or Godot with `goatsd`, so a `PROTOCOL_VERSION` bump or a stale
# extension hides here: the reference client's ALPN never negotiates, it simply never
# joins, and no Godot-to-Godot run goes red. It needs a window, because the reference
# client is a raylib app, like `shot`.
#
# Overrides: GODOT_BIN (the engine), GOATSD_BIN (the server), GOATS_BIN (the
# reference client, `jsjoin`), GOATSD_HERD (the host's herd size -- `--herd`; the
# `herd` mode at a large count is what shows the world datagram carries the larger
# herd), and GOATSD_FLAGS (extra server flags, word-split -- e.g.
# `GOATSD_FLAGS=--one-endpoint` to host the session on the discovery endpoint).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
godot_dir=$root/godot
log=$root/target/interop-goatsd.log

# Every process gets a registry store of its own. The store is a redb file and its
# lock is exclusive, so a shared one is a *wait*, not a shared catalogue -- and a
# client waits for it on the one networking thread that also runs `join`, so the
# join never happens: these modes run two or three processes on one machine that
# all present the same `mods/`. `goatsd` takes `--registry-store`, the scene reads
# `GOATS_REGISTRY_STORE`, and the paths are relative because every process here
# runs with `$root` as its working directory.
registry_host=target/registry-host
registry_scene=target/registry-scene
registry_a=target/registry-a
registry_b=target/registry-b
registry_ref=target/registry-reference

# A release binary carries the platform's suffix -- `.exe` on Windows, nothing elsewhere -- so the
# default path is derived from `uname` rather than hard-coded, the way `crates/godot/build.sh` picks
# its platform. That is what lets the same script run the Linux CI job (`crates/godot/build.sh`'s
# `MINGW*` case, one spelling over).
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*|Windows*) exe_suffix=.exe ;;
    *) exe_suffix= ;;
esac

mode=${1:-join}
case "$mode" in
    join|refuse|pull|herd|pair|death|hostdeath|jsjoin|offline|shot) ;;
    *)
        echo "interop.sh: unknown mode '$mode' (want join, refuse, pull, herd, pair, death, hostdeath, jsjoin, offline or shot)" >&2
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
    GOATS_REGISTRY_STORE="$registry_host" timeout -k 10 300 "$godot_bin" --headless \
        --path "$(to_native "$godot_dir")" \
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
    GOATSD_TICKET="$ticket" GOATS_REGISTRY_STORE="$registry_scene" \
        timeout -k 10 240 "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
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

# `jsjoin` is the one mode whose *joiner* is not a Godot peer: it is the reference (raylib/JavaScript)
# client, the other implementation of the same protocol, joined to *this scene's own host*. Every
# other mode pairs Godot with Godot or with `goatsd`, and none of them joins this scene's host from
# the other client, which is where a `PROTOCOL_VERSION` bump or a stale extension hides: the
# reference client's ALPN never negotiates, so it simply never joins, and no Godot-to-Godot mode goes
# red. It needs a window (the joiner is a raylib app), and there is no `goatsd` in it at all, so it
# returns here rather than falling through to the server the other modes start.
if [ "$mode" = "jsjoin" ]; then
    goats_bin=${GOATS_BIN:-$root/target/release/goats$exe_suffix}
    if [ ! -x "$goats_bin" ]; then
        echo "interop.sh: $goats_bin is not built; run:" >&2
        echo "    cargo build --release -p goats" >&2
        exit 1
    fi
    host_log=$root/target/host-reference.log
    client_log=$root/target/reference-join.log
    : > "$host_log"
    : > "$client_log"

    # The scene resolves `mods/` from the working directory and the reference client must present
    # the same world-mod set, so both run at the root.
    cd "$root"
    GOATS_REGISTRY_STORE="$registry_host" timeout -k 10 300 "$godot_bin" --headless \
        --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_host_reference.gd > "$host_log" 2>&1 &
    host_pid=$!
    cleanup_jsjoin() {
        kill "$host_pid" 2>/dev/null || true
    }
    trap cleanup_jsjoin EXIT INT TERM

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
    echo "interop.sh: this scene is hosting; the reference client will join (jsjoin mode)"

    set +e
    # The reference client's console is a line-based stdin/stdout channel: `connect <ticket>
    # <name>`, then a `net` read whose reply is the evidence it *joined* (`"mode":"client"`),
    # then a clean `quit`. The delay keeps the read inside the host's own hold window.
    ( printf 'connect %s jsgoat\n' "$ticket"; sleep 8; printf 'net\n'; sleep 1; printf 'quit\n' ) \
        | GOATS_REGISTRY_STORE="$registry_ref" \
            timeout 60 "$goats_bin" --mods mods > "$client_log" 2>&1
    client_status=$?
    wait "$host_pid"
    host_status=$?
    set -e

    # Both ends are read, not only the exit codes: which end failed is the first thing worth
    # knowing, and a client that never joined is the whole point of the mode.
    grep -E "^(OK|FAIL|peer|herd|host)" "$host_log" || true
    joined=$(grep -c '"mode":"client"' "$client_log" || true)
    if [ "$host_status" -ne 0 ] || [ "$client_status" -ne 0 ] || [ "$joined" -eq 0 ]; then
        echo "interop.sh: the reference client did not join this scene's session. Its output:" >&2
        grep -E "^(ok|error)" "$client_log" | head -20 >&2
        exit 1
    fi
    echo "interop.sh: a reference client joined this scene's own host and mirrored its herd"
    exit 0
fi

# Which world-mod set `goatsd` requires. `join` and `refuse` run a bare
# `verify_interop.gd` probe with no `ModHost` behind it, so it presents *nothing*:
# `join` gives it a host that requires nothing (`--no-mods`), and `refuse` a host
# that requires the repository's world mods -- the digest refusal. `pull` is the
# same modless probe against that same modded host, but it *fetches* what the
# refusal named (M18d), so it presents nothing and leaves running everything.
# `herd`, `pair` and `shot` run the real *scene*, which presents the repository's own
# set (`mods.world_mod_refs`), so the host runs the same mods and the join is accepted.
case "$mode" in
    join) mods_flag=--no-mods ;;
    herd|pair|shot|death|refuse|pull) mods_flag= ;;
esac

server=${GOATSD_BIN:-$root/target/release/goatsd$exe_suffix}
if [ ! -x "$server" ]; then
    echo "interop.sh: $server is not built; run:" >&2
    echo "    cargo build --release -p server" >&2
    exit 1
fi

# goatsd resolves `mods/` from the working directory, so start it at the root.
cd "$root"
: > "$log"
# `GOATSD_HERD`, when set, sizes the host's herd through the shipping `--herd` flag:
# `herd` at a large count is the only run that proves the world datagram carries it.
"$server" godot-host $mods_flag --registry-store "$registry_host" ${GOATSD_HERD:+--herd "$GOATSD_HERD"} ${GOATSD_FLAGS:+$GOATSD_FLAGS} > "$log" 2>&1 &
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
    GOATSD_TICKET="$ticket" GOATS_REGISTRY_STORE="$registry_a" \
        timeout -k 10 240 "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_peers_live.gd > "$a" 2>&1 &
    pid_a=$!
    GOATSD_TICKET="$ticket" GOATS_REGISTRY_STORE="$registry_b" \
        timeout -k 10 240 "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
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
    grep -E "^(OK|FAIL|peers:|flew:)" "$a" || true
    grep -E "^(OK|FAIL|peers:|flew:)" "$b" || true
elif [ "$mode" = "herd" ]; then
    # The real scene, with the probe switched on: it settles, reports and exits. `GOATSD_HERD`
    # is handed through as `GOATS_PROBE_HERD`, so a large herd is not only *mirrored* but
    # *checked*: the probe insists the mirror holds exactly the count the host was asked for,
    # which a client emitting one part of a split snapshot would fail.
    GOATSD_TICKET="$ticket" GOATS_PROBE=1 GOATS_PROBE_HERD="${GOATSD_HERD:-}" \
        GOATS_REGISTRY_STORE="$registry_scene" \
        timeout -k 10 240 "$godot_bin" --headless --path "$(to_native "$godot_dir")"
    status=$?
elif [ "$mode" = "death" ]; then
    # The real scene, and the probe that kills and respawns its own goat: what a client's *own*
    # death has to leave alone is the herd it mirrors, which is the host's.
    GOATSD_TICKET="$ticket" GOATS_REGISTRY_STORE="$registry_scene" \
        timeout -k 10 240 "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_herd_death.gd
    status=$?
elif [ "$mode" = "pull" ]; then
    # The same modless probe and the same modded host as `refuse`, plus the consent: the probe
    # fetches the host's world mods into a directory of its *own* (`res://` is not written, and
    # neither is the repository's `mods/`), and joins on the retry. Both ends are the shipping
    # code -- the archive travels the fetch ALPN and `crates/pull` hashes it back to the digest
    # the host announced -- which is why this is the evidence `refuse` alone cannot give.
    GOATSD_TICKET="$ticket" GOATSD_EXPECT=pull \
        "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_interop.gd
    status=$?
elif [ "$mode" = "shot" ]; then
    # The real scene, in a window, long enough for a populated world to arrive and
    # for the herd to ease onto the ground under it. See `tools/screenshot.gd`.
    GOATSD_TICKET="$ticket" GOATS_SHOT_FRAMES=${GOATS_SHOT_FRAMES:-600} \
        GOATS_REGISTRY_STORE="$registry_scene" \
        "$godot_bin" --path "$(to_native "$godot_dir")" \
        --script res://tools/screenshot.gd --resolution ${GOATS_SHOT_RESOLUTION:-1280x720}
    status=$?
    echo "interop.sh: wrote $godot_dir/shot.png"
else
    GOATSD_TICKET="$ticket" GOATSD_EXPECT="$mode" GOATS_REGISTRY_STORE="$registry_scene" \
        timeout -k 10 240 "$godot_bin" --headless --path "$(to_native "$godot_dir")" \
        --script res://tools/verify_interop.gd
    status=$?
fi
set -e

# 124 is `timeout`'s: the scene was killed rather than failing. It used to be a CI
# job that sat on this step until the hour ran out, so it gets a line of its own.
if [ "$status" -eq 124 ]; then
    echo "interop.sh: ${mode} did not finish inside its timeout; the scene was killed" >&2
fi

echo "---- goatsd said ----"
# The session's own view: joins, leaves, the roster and chat.
grep -E "world mods|world set|joined|left|roster|chat|\[net\]" "$log" || true

exit "$status"
