# cloud-init server OCI image
#
# Build:
#   buildah bud --build-arg SOURCE_REF=v1.4.0 -t localhost/cloud-init:v1.4.0 images/cloud-init/
#
ARG GO_VERSION=1.24

# ---------- builder ----------
# Use Debian-based golang image because DuckDB's vendored static library
# is built for glibc (references __memcpy_chk, __memset_chk).
FROM golang:${GO_VERSION}-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        git gcc g++ \
    && rm -rf /var/lib/apt/lists/*

ARG SOURCE_REPO=https://github.com/openchami/cloud-init.git
ARG SOURCE_REF=main

WORKDIR /src
RUN git clone "${SOURCE_REPO}" . \
    && git checkout "${SOURCE_REF}"

RUN go build -o /out/cloud-init-server ./cmd/cloud-init-server

# ---------- runtime ----------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl ca-certificates iproute2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/cloud-init-server /usr/local/bin/cloud-init-server

CMD ["cloud-init-server"]
