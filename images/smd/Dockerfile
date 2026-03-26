# SMD (State Management Daemon) OCI image
#
# Build:
#   buildah bud --build-arg SOURCE_REF=v2.19.2 -t localhost/smd:v2.19.2 images/smd/
#
ARG GO_VERSION=1.24
ARG ALPINE_VERSION=3.20

# ---------- builder ----------
FROM golang:${GO_VERSION}-alpine AS builder

RUN apk add --no-cache git

ARG SOURCE_REPO=https://github.com/openchami/smd.git
ARG SOURCE_REF=main

WORKDIR /src
RUN git clone "${SOURCE_REPO}" . \
    && git checkout "${SOURCE_REF}"

RUN go build -o /out/smd           ./cmd/smd \
    && go build -o /out/smd-init   ./cmd/smd-init

# Copy migrations for the runtime image
RUN cp -r /src/migrations /out/migrations

# ---------- runtime ----------
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache bash curl ca-certificates

COPY --from=builder /out/smd          /usr/local/bin/smd
COPY --from=builder /out/smd-init     /usr/local/bin/smd-init
COPY --from=builder /out/migrations   /persistent_migrations/

CMD ["smd"]
