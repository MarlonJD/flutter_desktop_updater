# Linux native install helper

This package is distributed source-first. Build it with CMake and link the
`desktop_updater::native` target, or install it and use the generated CMake
export or `desktop_updater_native.pc` metadata.

Generic prebuilt Linux binaries are intentionally not published. A future
binary distribution must define and verify a compiler, glibc, architecture
matrix before advertising compatibility.
