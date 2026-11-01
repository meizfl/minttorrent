FROM docker.io/library/ubuntu:20.04

ARG DEBIAN_FRONTEND=noninteractive
ARG GO_VERSION=1.25.0
ARG CMAKE_VERSION=3.31.10
ARG QT_VERSION=6.6.3
ARG BOOST_VERSION=1.86.0
ARG OPENSSL_VERSION=3.0.16

ENV TZ=Etc/UTC \
    PATH=/opt/minttorrent-deps/bin:/usr/local/go/bin:/usr/local/bin:/usr/bin:/bin \
    CC=gcc-10 \
    CXX=g++-10 \
    CMAKE_PREFIX_PATH=/opt/minttorrent-deps

RUN apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=5 update \
    && apt-get -o Acquire::ForceIPv4=true -o Acquire::Retries=5 install -y --no-install-recommends \
      build-essential gcc-10 g++-10 ninja-build pkg-config git curl ca-certificates \
      perl python3 python3-pip python3-dev xz-utils bzip2 unzip \
      zlib1g-dev libzstd-dev libbrotli-dev libsqlite3-dev libdbus-1-dev \
      libxcb1-dev libx11-dev libxkbcommon-dev libxkbcommon-x11-dev \
      libxext-dev libxfixes-dev libxi-dev libxrender-dev libxcb-glx0-dev \
      libxcb-icccm4-dev libxcb-image0-dev libxcb-keysyms1-dev libxcb-randr0-dev \
      libxcb-render-util0-dev libxcb-shape0-dev libxcb-shm0-dev libxcb-sync-dev \
      libxcb-xfixes0-dev libxcb-xkb-dev libxcb-xinerama0-dev libxcb-xinput-dev \
      libxcb-cursor-dev libgl1-mesa-dev libegl1-mesa-dev libfontconfig1-dev \
      libfreetype6-dev libharfbuzz-dev libicu-dev libpng-dev libjpeg-dev \
      libdouble-conversion-dev libmd4c-dev libpcre2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir "cmake==${CMAKE_VERSION}"

RUN set -eux; \
    mkdir -p /tmp/toolchain /opt/minttorrent-deps; \
    curl -fsSLo /tmp/go.tar.gz "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"; \
    tar -C /usr/local -xzf /tmp/go.tar.gz; \
    rm /tmp/go.tar.gz; \
    curl -fsSLo /tmp/boost.tar.gz "https://archives.boost.io/release/${BOOST_VERSION}/source/boost_1_86_0.tar.gz"; \
    tar -C /tmp/toolchain -xzf /tmp/boost.tar.gz; \
    cd /tmp/toolchain/boost_1_86_0; \
    ./bootstrap.sh --prefix=/opt/minttorrent-deps --with-libraries=system; \
    ./b2 -d0 -j4 install; \
    curl -fsSLo /tmp/openssl.tar.gz "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"; \
    tar -C /tmp/toolchain -xzf /tmp/openssl.tar.gz; \
    cd /tmp/toolchain/openssl-${OPENSSL_VERSION}; \
    ./Configure linux-x86_64 shared no-tests --prefix=/opt/minttorrent-deps --openssldir=/opt/minttorrent-deps/ssl --libdir=lib; \
    make -s -j4; \
    make -s install_sw; \
    curl -fsSLo /tmp/qt.tar.xz "https://download.qt.io/archive/qt/6.6/${QT_VERSION}/single/qt-everywhere-src-${QT_VERSION}.tar.xz"; \
    tar -C /tmp/toolchain -xf /tmp/qt.tar.xz; \
    cd /tmp/toolchain/qt-everywhere-src-${QT_VERSION}; \
    ./configure -prefix /opt/minttorrent-deps -opensource -confirm-license -release \
      -nomake examples -nomake tests -submodules qtbase,qttools,qtsvg -no-feature-dbus \
      -- -GNinja -DCMAKE_C_COMPILER=gcc-10 -DCMAKE_CXX_COMPILER=g++-10 \
         -DQT_BUILD_TESTS=OFF -DQT_BUILD_EXAMPLES=OFF -DOPENSSL_ROOT_DIR=/opt/minttorrent-deps; \
    cmake --build . --parallel 4; \
    cmake --install .; \
    rm -rf /tmp/toolchain /tmp/boost.tar.gz /tmp/openssl.tar.gz /tmp/qt.tar.xz

WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
