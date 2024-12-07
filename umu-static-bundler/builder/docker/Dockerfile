FROM alpine:3.20 AS deps-builder

# Build environment setup
ENV CC=clang \
    CXX=clang++ \
    LD=ld.lld \
    AR=llvm-ar \
    NM=llvm-nm \
    RANLIB=llvm-ranlib \
    CFLAGS="-march=x86-64 -static -fPIC --target=x86_64-alpine-linux-musl -Oz -ffunction-sections -fdata-sections" \
    CXXFLAGS="-march=x86-64 -static -fPIC --target=x86_64-alpine-linux-musl -Oz -ffunction-sections -fdata-sections" \
    LDFLAGS="-static -Wl,--gc-sections,--strip-all" \
    PKG_CONFIG="pkg-config --static"

# Base build dependencies
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

# Build zstd
WORKDIR /build/zstd
COPY build/zstd .
RUN make -j"$(nproc)" && \
    cd lib && \
    make libzstd.pc && \
    install -Dm644 libzstd.pc /usr/local/lib/pkgconfig/libzstd.pc && \
    cd .. && \
    install -Dm644 lib/libzstd.a /usr/local/lib/libzstd.a && \
    install -Dm644 lib/zstd.h /usr/local/include/zstd.h && \
    install -Dm644 lib/zdict.h /usr/local/include/zdict.h && \
    install -Dm644 lib/zstd_errors.h /usr/local/include/zstd_errors.h && \
    install -Dm755 programs/zstd /usr/local/bin/zstd && \
    ln -sf /usr/local/bin/zstd /usr/local/bin/zstdmt && \
    ln -sf /usr/local/bin/zstd /usr/local/bin/unzstd

# Build libarchive
WORKDIR /build/libarchive
COPY build/libarchive .
RUN PKG_CONFIG_PATH="/usr/local/lib/pkgconfig" \
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

# Build environment configuration
ENV PATH="/opt/build-env/bin:$PATH" \
    PKG_CONFIG="pkg-config --static"

# Runtime dependencies 
RUN apk add --no-cache \
    build-base \
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

# Copy built dependencies from deps-builder
COPY --from=deps-builder /usr/local/lib/libzstd.a /usr/local/lib/
COPY --from=deps-builder /usr/local/include/zstd*.h /usr/local/include/
COPY --from=deps-builder /usr/local/lib/pkgconfig/libzstd.pc /usr/local/lib/pkgconfig/
COPY --from=deps-builder /usr/local/bin/zstd* /usr/local/bin/
COPY --from=deps-builder /build/install/usr/local/lib/libarchive.a /usr/local/lib/
COPY --from=deps-builder /build/install/usr/local/include/archive*.h /usr/local/include/
COPY --from=deps-builder /build/install/usr/local/bin/bsdtar /usr/local/bin/

# Build system setup
COPY build/lib/ /build/lib/
RUN chmod +x /build/lib/docker-build.sh

WORKDIR /build
ENTRYPOINT ["/build/lib/docker-build.sh"]