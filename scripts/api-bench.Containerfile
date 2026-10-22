FROM ubuntu:24.04

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      libcurl4t64 \
      libsqlite3-0 \
      libssl3t64 \
      python3 \
 && rm -rf /var/lib/apt/lists/*

COPY pabrik /opt/pabrik/pabrik
COPY api_bench.py /opt/pabrik/api_bench.py

ENV HOME=/pabrik-home
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

WORKDIR /opt/pabrik
