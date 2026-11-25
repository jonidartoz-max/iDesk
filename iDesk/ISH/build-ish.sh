#!/bin/bash
# Rebuilds the iSH-ARM64 static libraries in this directory (lib/) from source,
# in the iDesk xtool/Linux build lane (no macOS, no Xcode). Mirrors OpenMinis'
# deps/build_ish.sh (github.com/OpenMinis/OpenMinis), with the cross file
# pointing at the lane's swift60 clang + iPhoneOS SDK bundle.
#
# Prereqs in the lane: pip3 install meson ninja; swift60 toolchain at
# /home/sandbox/swift60; the iOS SDK bundle under ~/.swiftpm/swift-sdks.
set -e

ISH=/tmp/ish                       # clone of github.com/OpenMinis/ish-arm64, branch feature-arm64
SWIFT=/home/sandbox/swift60/usr/bin
SDK=$(find /home/sandbox/.swiftpm/swift-sdks -maxdepth 6 -name 'iPhoneOS.sdk' -type d | head -1)

# 1. Static libraries (libish.a, libish_emu.a, libfakefs.a) + guest VDSO
mkdir -p "$ISH/build-ios"
cat > "$ISH/build-ios/ios-cross.txt" <<EOF
[binaries]
c = ['$SWIFT/clang', '-target', 'arm64-apple-ios17.0', '-isysroot', '$SDK', '-fuse-ld=lld']
ar = '$SWIFT/llvm-ar'
strip = 'true'
pkg-config = 'false'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_link_args = ['-L$SDK/usr/lib']

[properties]
needs_exe_wrapper = true
sys_root = '$SDK'
library_dirs = ['$SDK/usr/lib']
EOF

cd "$ISH"
PATH=$SWIFT:$PATH meson setup build-ios --cross-file build-ios/ios-cross.txt \
    --buildtype=release -Db_ndebug=true -Dlog= -Dlog_handler=nslog \
    -Dkernel=ish -Dengine=asbestos -Dguest_arch=arm64
PATH=$SWIFT:$PATH ninja -C build-ios libish.a libish_emu.a libfakefs.a vdso/arm64/libvdso.so.elf
cp build-ios/libish.a build-ios/libish_emu.a build-ios/libfakefs.a lib/
cp build-ios/vdso/arm64/libvdso.so.elf lib/

# 2. fakefsify (host tool, Linux): packs the Alpine minirootfs into fakefs format
curl -sL -o /tmp/alpine.tar.gz \
    https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/aarch64/alpine-minirootfs-3.21.0-aarch64.tar.gz
gcc -O2 tools/fakefsify.c tools/fakefs.c util/fchdir.c fs/fake-db.c fs/fake-migrate.c fs/fake-rebuild.c \
    tools-support/logstub.c -I. -Ideps/libarchive/libarchive \
    /lib/x86_64-linux-gnu/libarchive.so.13 /lib/x86_64-linux-gnu/libsqlite3.so.0 -o /tmp/fakefsify
rm -rf alpine-rootfs
/tmp/fakefsify /tmp/alpine.tar.gz alpine-rootfs

# 3. Headers for the app side (ish/)
for d in emu kernel fs util platform asbestos deps; do
    (cd "$ISH" && find $d -maxdepth 3 -name '*.h' -exec cp --parents {} "$OLDPWD/ish/" \;)
done
cp "$ISH"/{misc.h,debug.h,xX_main_Xx.h} ish/
cp "$ISH/build-ios/cpu-offsets.h" ish/
echo "Done: lib/, ish/, alpine-rootfs/"
