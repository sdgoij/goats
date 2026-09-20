#!/bin/sh
# The engine-cost benchmark (PERF.md appendix B): one variant per process, because a
# configuration command between two windows collapses the second window. Each run
# writes bench-<kind>.log; the analysis is an awk over those (see PERF.md).
#
# `perf loop <kind> 200` arms 200 iterations of that body a frame; `ping` brackets the
# 24 s window so the collector's own lines can be sliced exactly. Sound is off in every
# run -- the same configuration for every variant, and quiet.

( echo "mute on"; echo "setting fullscreen off"; echo "perf loop none 0"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-none.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop arith 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-arith.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop arithinline 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-arithinline.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop global 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-global.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop field 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-field.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop fieldset 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-fieldset.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop index 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-index.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop sqrt 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-sqrt.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop new 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-new.log 2>&1
( echo "mute on"; echo "setting fullscreen off"; echo "perf loop call 200"; sleep 10; echo "ping"; sleep 24; echo "ping"; echo "perf loop"; echo "quit" ) | timeout 60 ./target/release/goats.exe --gc-trace > bench-call.log 2>&1
