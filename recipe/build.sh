#!/usr/bin/env bash
set -euo pipefail

# Fetch zig dependencies into an offline cache. This step requires network and
# is shared by both branches — Ghostty's macOS Xcode project also shells out
# to zig for the core terminal libs.
export ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-cache"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"
./nix/build-support/fetch-zig-cache.sh

if [[ "${target_platform}" == osx-* ]]; then
    # ---------------- macOS branch ----------------
    # Per upstream's https://ghostty.org/docs/install/build, `zig build
    # -Doptimize=ReleaseFast` (no -Demit-macos-app=false) drives the whole
    # .app build — it produces the libghostty xcframework AND invokes
    # xcodebuild against it under the "ReleaseLocal" configuration, which
    # specifically disables Library Validation so the resulting bundle
    # works with ad-hoc signing (no Developer ID required). That's
    # exactly our situation, so we follow the documented recipe instead
    # of orchestrating xcframework + xcodebuild ourselves.

    # Ghostty 1.3.1's macOS sources reference Tahoe-era SDK symbols
    # (NSGlassEffectView, ConcentricRectangle, etc.) that aren't in
    # MacOSX15.5.sdk shipped with Xcode 16.4 — Backport.swift gates the
    # *uses* with @available, but the *symbols* still need to exist at
    # compile time, so we need an Xcode 26 SDK on the path. The Azure
    # macOS image ships multiple Xcodes; pick the highest 26.* if present.
    # Deployment target stays at 13.0 (set in the project), matching
    # upstream's published macOS 13 Ventura support floor.
    echo "==> Available Xcodes (and their SDKs):"
    for xc in /Applications/Xcode*.app; do
        [[ -e "$xc" ]] || continue
        xcb="$xc/Contents/Developer/usr/bin/xcodebuild"
        if [[ -x "$xcb" ]]; then
            ver=$("$xcb" -version 2>/dev/null | tr '\n' ' ')
            sdks=$("$xcb" -showsdks 2>/dev/null | grep -E 'macOS|macosx' | head -3 | tr '\n' ',' || true)
            echo "  $xc  ::  $ver  ::  SDKs: $sdks"
        else
            echo "  $xc  ::  (no xcodebuild)"
        fi
    done

    XCODE26="$(ls -d /Applications/Xcode_26*.app 2>/dev/null | sort -V | tail -1 || true)"
    if [[ -n "${XCODE26}" && -d "${XCODE26}/Contents/Developer" ]]; then
        export DEVELOPER_DIR="${XCODE26}/Contents/Developer"
        echo "==> Selecting ${DEVELOPER_DIR} for xcodebuild (Tahoe SDK)"
    else
        echo "==> ERROR: no Xcode 26 found on the runner; build will fail with"
        echo "    'cannot find type NSGlassEffectView in scope' against older SDKs."
        exit 1
    fi

    BUILD_DIR="${SRC_DIR}/build-macos"
    mkdir -p "${BUILD_DIR}"

    # Pick the build arch from target_platform. For osx-arm64 (native on
    # the runner) the xcframework "native" target is what we want. For
    # osx-64 we're cross-compiling from the arm64 runner — but zig's
    # xcframework "native" target is hardwired to the *zig host* arch
    # (aarch64 here) regardless of -Dtarget, and the enum has no
    # x86_64-only option, so we build the *universal* xcframework (which
    # includes the x86_64-macos slice — plus, wastefully, the iOS slices)
    # and let xcodebuild extract ARCHS=x86_64 from the fat lib.
    case "${target_platform}" in
        osx-arm64)
            xc_framework_target="native"
            xc_arch="arm64"
            ;;
        osx-64)
            xc_framework_target="universal"
            xc_arch="x86_64"
            ;;
        *)
            echo "ERROR: unexpected target_platform '${target_platform}'"; exit 1
            ;;
    esac
    echo "==> Building for ${target_platform}: xcframework=${xc_framework_target} arch=${xc_arch}"

    # Two-step build (instead of upstream's bundled `zig build` →
    # `xcodebuild -configuration ReleaseLocal`):
    #   1. zig build the xcframework (libghostty core).
    #   2. xcodebuild -configuration Release -scheme Ghostty for the .app.
    # We tried the bundled path; xcodebuild's ReleaseLocal config tripped
    # a Swift compile error in the Ghostty target that the Release config
    # doesn't (specific error text was truncated by cf-job-logs annotations).
    # Release + ad-hoc signing produces a working bundle, so we stick with
    # the more explicit flow.

    # Step 1: produce macos/GhosttyKit.xcframework.
    zig build \
        --system "${ZIG_GLOBAL_CACHE_DIR}/p" \
        -Doptimize=ReleaseFast \
        -Demit-macos-app=false \
        -Dxcframework-target="${xc_framework_target}" \
        -Dversion-string="${PKG_VERSION}-conda"

    # Step 2: xcodebuild against the xcframework produced above.
    # ARCHS=<arch> + ONLY_ACTIVE_ARCH=YES restricts to the one slice.
    xcodebuild \
        -project macos/Ghostty.xcodeproj \
        -scheme Ghostty \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -derivedDataPath "${BUILD_DIR}/DerivedData" \
        ARCHS="${xc_arch}" \
        ONLY_ACTIVE_ARCH=YES \
        SYMROOT="${BUILD_DIR}" \
        CODE_SIGN_IDENTITY=- \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES \
        OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
        MARKETING_VERSION="${PKG_VERSION}" \
        build

    APP_SRC="${BUILD_DIR}/Release/Ghostty.app"

    # Re-sign --deep --force so embedded helpers/frameworks inherit a
    # consistent ad-hoc signature. xcodebuild signs the outer bundle but
    # can leave deeper Mach-Os (Sparkle.framework's helpers) untouched.
    /usr/bin/codesign --force --deep --sign - "${APP_SRC}"
    /usr/bin/codesign --verify --deep --strict "${APP_SRC}"

    # Layout:
    #   $PREFIX/Applications/Ghostty.app  — full bundle for `open` / GUI
    #   $PREFIX/bin/ghostty               — shim into the dual-mode binary
    # The same Mach-O handles `+help` / `--version` (CLI mode) and GUI.
    mkdir -p "${PREFIX}/Applications" "${PREFIX}/bin"
    cp -R "${APP_SRC}" "${PREFIX}/Applications/Ghostty.app"

    cat > "${PREFIX}/bin/ghostty" <<'SHIM'
#!/usr/bin/env bash
exec "$(dirname "$0")/../Applications/Ghostty.app/Contents/MacOS/ghostty" "$@"
SHIM
    chmod +x "${PREFIX}/bin/ghostty"

    mkdir -p "${PREFIX}/Menu"
    cp "${RECIPE_DIR}/Menu/ghostty.json" "${PREFIX}/Menu/ghostty.json"
    # Icon ships inside Ghostty.app; menuinst points at it via CFBundleIconFile.

    exit 0
fi

# ---------------- Linux branch ----------------

# Generate a libc.txt that points zig at the conda toolchain instead of the
# system /lib64 / /usr/include. zig build doesn't go through the conda zig-cc
# wrapper so it would otherwise try to link against the host's libc.
gcc_dir="$(dirname "$(${HOST}-gcc -print-libgcc-file-name)")"
libc_txt="${SRC_DIR}/conda-libc.txt"
cat > "${libc_txt}" <<EOF
include_dir=${BUILD_PREFIX}/${HOST}/sysroot/usr/include
sys_include_dir=${BUILD_PREFIX}/${HOST}/sysroot/usr/include
crt_dir=${BUILD_PREFIX}/${HOST}/sysroot/usr/lib64
msvc_lib_dir=
kernel32_lib_dir=
gcc_dir=${gcc_dir}
EOF

# When --sysroot is passed to zig, every -L path (including the conda host
# ${PREFIX}/lib) gets prepended with the sysroot — so zig ends up looking for
# libbz2.so etc. at ${SYSROOT}${PREFIX}/lib, which doesn't exist. Mirror the
# host include / lib trees inside the sysroot so the prefixed paths resolve.
sysroot_dir="${BUILD_PREFIX}/${HOST}/sysroot"
mkdir -p "${sysroot_dir}$(dirname "${PREFIX}")"
ln -sfn "${PREFIX}" "${sysroot_dir}${PREFIX}"

# ghostty's build.zig calls linkSystemLibrary2("bzip2", ...) which makes zig
# search for libbzip2.so — conda-forge's bzip2 package ships libbz2.so.* only
# (the SONAME). Bridge the name with a build-time symlink so the linker can
# resolve it; the actual SONAME embedded in the binary stays libbz2.so, so the
# runtime dependency on conda-forge bzip2 stays correct. The symlink is
# removed before packaging.
bzip2_compat_link="${PREFIX}/lib/libbzip2.so"
ln -sf libbz2.so "${bzip2_compat_link}"

extra_flags=()
# Used only for local iteration on linux-aarch64 where gtk4-layer-shell is
# not packaged yet. The aarch64 platform is skipped in recipe.yaml so this
# branch is never taken in CI.
if [[ "${GHOSTTY_NO_WAYLAND:-0}" == "1" ]]; then
    extra_flags+=(-Dgtk-wayland=false)
fi

# Build ghostty using the prefetched cache. No further network is needed.
zig build \
    --prefix "${PREFIX}" \
    --system "${ZIG_GLOBAL_CACHE_DIR}/p" \
    --sysroot "${sysroot_dir}" \
    --libc "${libc_txt}" \
    --search-prefix "${PREFIX}" \
    -Doptimize=ReleaseFast \
    -Dcpu=baseline \
    -Dversion-string="${PKG_VERSION}-conda" \
    -Dpie=true \
    "${extra_flags[@]}"

# Drop the bzip2 build-time symlink so it doesn't ship in the package.
rm -f "${bzip2_compat_link}"

# Ghostty's auto resource-dir detection (src/os/resourcesdir.zig) walks up
# from the binary looking for share/terminfo/g/ghostty or
# share/terminfo/x/xterm-ghostty as a sentinel. Newer ncurses lays entries
# out by hex code (terminfo/78/xterm-ghostty) and ghostty installs a
# relative letter-form symlink pointing at it — but rattler-build's
# prefix-rewriting drops that symlink because its target uses an unusual
# ".././78/..." form. Without the sentinel ghostty falls back to no
# resource dir, so `+list-themes` and shell integration both come up
# empty. Recreate clean symlinks (the actual entry stays under 78/).
if [[ -f "${PREFIX}/share/terminfo/78/xterm-ghostty" ]]; then
    mkdir -p "${PREFIX}/share/terminfo/x" "${PREFIX}/share/terminfo/g"
    ln -sfn ../78/xterm-ghostty "${PREFIX}/share/terminfo/x/xterm-ghostty"
    ln -sfn ../78/xterm-ghostty "${PREFIX}/share/terminfo/g/ghostty"
fi

# Install menuinst entry for the system app menu (pixi/conda menu integration).
mkdir -p "${PREFIX}/Menu"
cp "${RECIPE_DIR}/Menu/ghostty.json" "${PREFIX}/Menu/ghostty.json"
cp "${SRC_DIR}/images/gnome/512.png" "${PREFIX}/Menu/ghostty.png"
