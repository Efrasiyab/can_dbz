FROM debian:bookworm-slim

ARG ZIG_VERSION=0.17.0
ARG CANTOOLS_VERSION=40.7.1
ARG ZIG_SHA256_X86_64=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ARG ZIG_SHA256_AARCH64=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl xz-utils git make python3 python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/cantools \
    && /opt/cantools/bin/pip install --no-cache-dir "cantools==${CANTOOLS_VERSION}"

RUN set -eux; \
    arch="$(uname -m)"; \
    case "$arch" in \
        x86_64) sha="$ZIG_SHA256_X86_64" ;; \
        aarch64) sha="$ZIG_SHA256_AARCH64" ;; \
        *) echo "unsupported arch: $arch" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/zig.tar.xz "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz"; \
    echo "${sha}  /tmp/zig.tar.xz" | sha256sum -c -; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig

ENV ZIG_GLOBAL_CACHE_DIR=/var/cache/zig
ENV PATH="/opt/cantools/bin:${PATH}"

WORKDIR /workspace

CMD ["bash"]
