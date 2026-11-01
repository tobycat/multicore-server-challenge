#!/usr/bin/env bash
# Assembles src/*.s with GNU as and links ./conduit statically: no libc, no CRT, raw syscalls only.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
objs=()
for m in main rt crypto json bcrypt gzip sql pg db http; do
  as --64 -I src -o "build/$m.o" "src/$m.s"
  objs+=("build/$m.o")
done
ld -static -nostdlib -z noexecstack -e _start -o conduit "${objs[@]}"
