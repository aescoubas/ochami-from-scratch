# PCS (Power Control Service) OCI image
#
# Build:
#   buildah bud --build-arg SOURCE_REF=main -t localhost/pcs:main images/pcs/
#
ARG GO_VERSION=1.24

# ---------- builder ----------
# Use Debian-based golang image because confluent-kafka-go vendors
# librdkafka_glibc_linux_amd64.a which requires glibc.
FROM golang:${GO_VERSION}-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git patch gcc pkg-config \
    && rm -rf /var/lib/apt/lists/*

ARG SOURCE_REPO=https://github.com/OpenCHAMI/power-control.git
ARG SOURCE_REF=main

WORKDIR /src
RUN git clone "${SOURCE_REPO}" . \
    && git checkout "${SOURCE_REF}"

# Apply local patches
COPY patches/ /tmp/patches/
RUN for p in /tmp/patches/*.patch; do \
        [ -f "$p" ] && patch -p1 < "$p"; \
    done

RUN go build -o /out/power-control ./cmd/power-control

# Copy configs and migrations for the runtime image
RUN cp -r /src/configs    /out/configs \
    && cp -r /src/migrations /out/migrations

# ---------- runtime ----------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=builder /out/power-control  /usr/local/bin/power-control
COPY --from=builder /out/configs        /app/configs/
COPY --from=builder /out/migrations     /app/migrations/

CMD ["power-control"]
