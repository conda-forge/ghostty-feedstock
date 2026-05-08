#!/usr/bin/env bash
set -euo pipefail

# Fetch zig dependencies into an offline cache. This step requires network.
export ZIG_GLOBAL_CACHE_DIR="${SRC_DIR}/zig-cache"
mkdir -p "${ZIG_GLOBAL_CACHE_DIR}"
./nix/build-support/fetch-zig-cache.sh

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
