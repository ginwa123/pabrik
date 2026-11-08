ARG UBUNTU_VERSION=24.04

# The object store that holds document bodies. Pinned and sha256-verified, the
# same way scripts/stage-bundled-rustfs.sh does it for the installers. It lands
# as `pabrik-fs` so the process is identifiable and never shadows a `rustfs`
# the user installed. The asset ids below are rustfs 1.0.4's; the
# `releases/download/<tag>/<name>` URL 504s for these assets, the API asset
# endpoint does not.
FROM ubuntu:${UBUNTU_VERSION} AS rustfs

ARG RUSTFS_VERSION=1.0.4

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$(uname -m)" in \
      x86_64) rustfs_asset=675522651; rustfs_sha=4a25e48f5b5ae610a679b5324206962c6fb0eb20a9fa7ab6cb20e178cf6c534b ;; \
      aarch64 | arm64) rustfs_asset=675521975; rustfs_sha=5c2d4dad2685f41635441b685dc4dead225f84bce2a9a365d87f8151ec88a049 ;; \
      *) echo "unsupported build architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL --retry 3 -H "Accept: application/octet-stream" \
      "https://api.github.com/repos/rustfs/rustfs/releases/assets/${rustfs_asset}" -o /tmp/rustfs.zip; \
    echo "${rustfs_sha}  /tmp/rustfs.zip" | sha256sum -c -; \
    unzip -p /tmp/rustfs.zip rustfs > /usr/local/bin/pabrik-fs; \
    chmod 0755 /usr/local/bin/pabrik-fs; \
    rm /tmp/rustfs.zip; \
    /usr/local/bin/pabrik-fs --version

FROM ubuntu:${UBUNTU_VERSION} AS build

ARG ZIG_VERSION=0.16.0
ARG OPTIMIZE=ReleaseFast
ARG SAAS=0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      git \
      libcurl4-openssl-dev \
      libpq-dev \
      libsqlite3-dev \
      libssl-dev \
      pkg-config \
      unzip \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    case "$(uname -m)" in \
      x86_64) zig_arch=x86_64 ;; \
      aarch64 | arm64) zig_arch=aarch64 ;; \
      *) echo "unsupported build architecture: $(uname -m)" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${zig_arch}-linux-${ZIG_VERSION}.tar.xz" -o /tmp/zig.tar.xz; \
    mkdir -p /opt/zig; \
    tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1; \
    rm /tmp/zig.tar.xz; \
    ln -s /opt/zig/zig /usr/local/bin/zig; \
    zig version

WORKDIR /src
COPY . .

RUN set -eux; \
    if [ "${SAAS}" = "1" ]; then db_used=sqlite,postgres; else db_used=sqlite; fi; \
    zig build install:linux:system -Doptimize="${OPTIMIZE}" -Dno-webapp-rebuild -Ddb_used="${db_used}"

FROM ubuntu:${UBUNTU_VERSION} AS runtime

ARG SAAS=0

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      libcurl4t64 \
      libsqlite3-0 \
      libssl3t64 \
      ripgrep \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    if [ "${SAAS}" = "1" ]; then \
      apt-get update; \
      apt-get install -y --no-install-recommends libpq5; \
      rm -rf /var/lib/apt/lists/*; \
    fi

COPY --from=build /usr/local/bin/pabrik /usr/local/bin/pabrik
COPY --from=rustfs /usr/local/bin/pabrik-fs /usr/local/bin/pabrik-fs

ENV HOME=/data
RUN mkdir -p /data
VOLUME ["/data"]

EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/pabrik"]

FROM runtime AS saas
ENV PABRIK_DATABASE=postgres
CMD ["--no-static-dir", "--saas"]

FROM runtime AS default
CMD ["--no-static-dir"]
