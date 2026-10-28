# libghostty-vt packaging

The `ghostty` application and `libghostty-vt` library are independent outputs.
The application retains its Linux x86_64 GTK build and macOS arm64 Xcode app
build. Windows and Linux aarch64 skip the application; the latter cannot
resolve the application's gtk4-layer-shell dependency. macOS x86_64 remains
library-only because the application previously encountered a Zig codegen panic.

## Ghostty 1.4.0 release verification

Verified against the release archive, SHA-256
`cb188ac6c3a8278d5fd7bfef15d8c017104c87f638b5560eb38024a71ae0f005`:

- `build.zig.zon` requires Zig 0.17.0.
- `build.zig` builds shared and static VT libraries and installs the public C
  headers. `-Demit-lib-vt=true` selects the standalone library configuration.
- `src/build/GhosttyLibVt.zig` includes Unix PIC and Windows static-library
  support. No static-library patch is needed for this release.
- The static library is installed as `libghostty-vt.a` on Unix and
  `ghostty-vt-static.lib` on Windows, alongside the DLL import library
  `ghostty-vt.lib`.
- Upstream supplies both `libghostty-vt.pc` and `libghostty-vt-static.pc`.
- The old Xcode 16.4 Swift patch does not apply to the updated source and is
  removed. The Icon Composer references moved in the Xcode project; the existing
  headless-CI icon workaround is rebased to 1.4.0. `macos_icons.py` copies
  upstream PNGs into a classic AppIcon catalog, including correct 2x resolutions.
  The GUI build continues to require Xcode 26; native macOS validation needs CI.

The library build disables the executable, docs, macOS app, and XCFramework.
SIMD is disabled to avoid adding its C/C++ dependencies. The build reuses the
release's dependency-cache manifest and the existing Linux conda libc
configuration. Both builds use `zig_cache.py` and honor the toolchain's
`ZIG_GLOBAL_CACHE_DIR` when available. Python build helpers select the executable
from `ZIG` or `CONDA_ZIG_BUILD`, with a build-prefix fallback for the Windows
triplet-named compiler; the Windows toolchain need not provide a bare `zig.exe`. Zig 0.17 stores dependency archives under
`p/`; the helper unpacks them into hash-named directories under `conda-packages/`
for `--system`. Passing the archive directory directly to `--system`, as in the
old recipe, triggers an internal Zig panic.
Zig 0.17 uses `-Doptimize=fast`; its libc paths file also requires the
`darwin_sdk_dir` field (empty on Linux) and calls the compiler runtime directory
`cc_dir`. The `build-glibc-version.patch` adds a build option to constrain the
native build-helper target to the conda sysroot version. Without it, a newer
host glibc causes helper programs to reference `arc4random_buf`, unavailable in
the glibc 2.34 sysroot. The Linux application also passes an explicit
`-Dtarget=x86_64-linux-gnu.2.34` so `-Dcpu=baseline` cannot reintroduce native
glibc detection for its main executable. This patch does not implement library
artifacts. macOS uses its SDK/toolchain to build a dylib,
without invoking the Xcode application or creating a universal XCFramework.

Both libraries and all public VT headers are included in one package.
`lib/pkgconfig/libghostty-vt.pc` selects shared linking;
`lib/pkgconfig/libghostty-vt-static.pc` selects the archive explicitly. Windows
uses the corresponding layout under `Library/`. The recipe adds
`-DGHOSTTY_STATIC` to the static module's Cflags so Windows consumers use direct
C symbol references rather than dllimport declarations. Static Windows linking
also uses the NT/kernel32 system libraries, recorded in the static pkg-config
module as well as the MSVC smoke test.

The application output uses version `1.4.0` and the library output uses its own
upstream development version, normalized from `0.1.0-dev` to the conda-compatible
`0.1.0.dev`. The pkg-config metadata retains upstream spelling `0.1.0-dev`. Both are built
from the Ghostty 1.4.0 source archive; the library has no separately tagged
upstream release yet. If a later source snapshot retains the same development
version, increment the library build number to distinguish the package and its
exact ABI run export. An exact run export protects consumers of this experimental
C ABI. Compiler and C standard library run exports supply
platform runtime constraints. The old macOS Clang 20 compatibility pin used for
Zig 0.15.2 has been removed; Zig 0.17.0 solves with the default Clang 21 toolchain.

## Validation

The recipe includes package content assertions and C smoke tests which allocate
and free an OSC parser, linked separately against the shared library and static
archive. Unix tests use pkg-config flags; Windows checks pkg-config metadata
and uses the corresponding import/static library with MSVC.

Local validation passed for the release checksum, conda-smithy lint/rerender,
recipe rendering, dependency solves, Python/C/shell syntax, patch applicability,
and all ten fallback macOS icon PNG dimensions. Local Linux application and
library builds and tests passed; the library was initially tested under package
version 1.4.0 before its output version was separated.

CI for commit `254bd8d` subsequently built and tested the final output versions:

| Platform | Application | Library shared/static linking and runtime tests |
| --- | --- | --- |
| linux-64 | Passed | Passed |
| linux-aarch64 | Skipped | Passed |
| osx-arm64 | Passed, including Xcode/icon assets | Passed |
| osx-64 | Skipped | Passed |

Those four jobs failed only at conda-forge output validation because
`libghostty-vt` is not registered for `ghostty-feedstock`. This requires an
`add_feedstock_output` request in conda-forge/admin-requests; output validation
remains enabled in this feedstock.

The Windows job stopped before compilation: Python could not locate a bare
`zig` command. The executable-discovery fix uses the activated `ZIG` or
`CONDA_ZIG_BUILD` compiler, with a fallback to the triplet-named executable in
`BUILD_PREFIX/Library/bin`. Local checks exercised fetching with no bare `zig`
on PATH, each discovery route, and executable paths containing spaces; resolving
and invoking the actual Linux Zig 0.17.0 compiler also passed. Native Windows
compilation and runtime tests still need a CI retry with this fix.
