FROM alpine:3.20 AS builder

RUN apk add --no-cache \
    clang \
    clang-dev \
    llvm17 \
    lld \
    musl-dev \
    build-base \
    autoconf \
    automake \
    libtool \
    pkgconf \
    autoconf-archive \
    linux-headers

ENV PKG_CONFIG="pkg-config --static"

# Build static zstd first (gcc is bullshit on this for some reason)
WORKDIR /build/zstd
COPY zstd .
RUN CC=clang \
    CXX=clang++ \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    RANLIB=llvm-ranlib \
    CFLAGS="-static -fPIC --target=x86_64-alpine-linux-musl -Oz -ffunction-sections -fdata-sections" \
    CXXFLAGS="-static -fPIC --target=x86_64-alpine-linux-musl -Oz -ffunction-sections -fdata-sections" \
    LDFLAGS="-static -Wl,--gc-sections,--strip-all" \
    make -j"$(nproc)" && \
    cd lib && \
    make libzstd.pc && \
    install -Dm644 libzstd.pc /usr/local/lib/pkgconfig/libzstd.pc && \
    cd .. && \
    install -Dm644 lib/libzstd.a /usr/local/lib/libzstd.a && \
    find lib -name "zstd*.h" -exec install -Dm644 {} /usr/local/include/{} \; && \
    install -Dm755 programs/zstd /usr/local/bin/zstd && \
    ln -sf /usr/local/bin/zstd /usr/local/bin/zstdmt && \
    ln -sf /usr/local/bin/zstd /usr/local/bin/unzstd

# Build static libarchive with zstd support
WORKDIR /build/libarchive
COPY libarchive .
RUN CPPFLAGS="-I/usr/local/include" \
    CFLAGS="-static -Oz -fPIC -ffunction-sections -fdata-sections" \
    LDFLAGS="-static -Wl,--gc-sections,--strip-all -L/usr/local/lib" \
    PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
    autoreconf -fi && \
    ./configure \
        --enable-static \
        --enable-shared=no \
        --enable-bsdtar \
        --disable-bsdcat \
        --disable-bsdcpio \
        --disable-bsdunzip \
        --disable-acl \
        --disable-xattr \
        --disable-largefile \
        --disable-posix-regex-lib \
        --disable-rpath \
        --without-zlib \
        --without-bz2lib \
        --without-libb2 \
        --without-iconv \
        --without-lz4 \
        --with-zstd \
        --without-lzma \
        --without-lzo2 \
        --without-cng \
        --without-openssl \
        --without-xml2 \
        --without-expat \
        --without-nettle && \
    make -j"$(nproc)" && \
    make install-strip DESTDIR=/build/install

FROM alpine:3.20

ENV PATH="/opt/build-env/bin:$PATH" \
    PKG_CONFIG="pkg-config --static"

RUN apk add --no-cache \
    build-base \
    clang \
    clang-dev \
    llvm17 \
    lld \
    musl-dev \
    python3 \
    python3-dev \
    py3-installer \
    py3-pip \
    py3-setuptools \
    py3-wheel \
    git \
    make \
    linux-headers \
    bash \
    patch \
    pkgconf \
    scdoc && \
    python3 -m venv /opt/build-env && \
    /opt/build-env/bin/pip install --no-cache-dir build hatchling

COPY --from=builder /usr/local/lib/libzstd.a /usr/local/lib/
COPY --from=builder /usr/local/include/zstd*.h /usr/local/include/
COPY --from=builder /usr/local/lib/pkgconfig/libzstd.pc /usr/local/lib/pkgconfig/
COPY --from=builder /usr/local/bin/zstd* /usr/local/bin/
COPY --from=builder /build/install/usr/local/lib/libarchive.a /usr/local/lib/
COPY --from=builder /build/install/usr/local/include/archive.h /usr/local/include/
COPY --from=builder /build/install/usr/local/include/archive_entry.h /usr/local/include/
COPY --from=builder /build/install/usr/local/bin/bsdtar /usr/local/bin/

RUN mkdir -p /build/lib

WORKDIR /build

# entrypoint script and utils
COPY lib/messaging.sh /build/lib/
COPY umu-build.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/umu-build.sh

ENTRYPOINT ["/usr/local/bin/umu-build.sh"]