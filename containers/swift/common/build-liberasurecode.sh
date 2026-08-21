#!/bin/sh

# Build liberasurecode from source (fetched via sources.txt into
# /src/liberasurecode). Provides erasurecode.h + liberasurecode.so to compile
# the pyeclib C extension in the build stage, and stages the runtime .so under
# /lec-install for the final image to copy. Replaces the liberasurecode /
# liberasurecode-devel RPMs.
#
# CFLAGS="-Wno-error": liberasurecode v1.1.1 trips -Werror=address-of-packed-member
# on newer GCC, and its --disable-werror option is a no-op upstream.
#
# --disable-mmi: build a portable binary. By default configure bakes in the
# build HOST's SIMD instructions (SSE/AVX) at build time.
set -eux

cd /src/liberasurecode
# Build only the library subdir. "test" binaries fail to link against internal
# (non-exported) symbols (rs_galois_inverse, init_alg_sig, ...) on newer
# toolchains, and "doc" only builds Doxygen HTML we don't ship. We only need
# the library, headers and .pc file (all installed from the top-level Makefile).
sed -i 's/^SUBDIRS = src test doc/SUBDIRS = src/' Makefile.am
./autogen.sh
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --disable-mmi CFLAGS="-Wno-error"
make -j"$(nproc)"
make install DESTDIR=/lec-install
# Make it available on the live build filesystem so pyeclib compiles/links.
cp -a /lec-install/usr/. /usr/
# libtool archives are useless at runtime and can carry stale paths.
find /lec-install -name '*.la' -delete
ldconfig
