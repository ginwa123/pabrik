ARG UBUNTU_VERSION=24.04

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
