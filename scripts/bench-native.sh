#!/bin/sh
# Native many-body benchmark: scripts/bench-native.sh [nodes] [order] [opening] [leaf] [isolate]
set -e
cd "$(dirname "$0")/.."
printf 'pub const n: u32 = %s;\npub const order: f64 = %s;\npub const opening: f64 = %s;\npub const leaf: u32 = %s;\npub const isolate = %s;\n' "${1:-100000}" "${2:-8}" "${3:-1.5}" "${4:-32}" "${5:-false}" > src/core/bench_config.zig
exec zig run -O ReleaseFast src/core/bench.zig
