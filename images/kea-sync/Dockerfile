# kea-sync OCI image
#
# Build:
#   buildah bud --build-arg SOURCE_REF=main -t localhost/kea-sync:latest images/kea-sync/
#
ARG GO_VERSION=1.24
ARG ALPINE_VERSION=3.20

# ---------- builder ----------
FROM golang:${GO_VERSION}-alpine AS builder

RUN apk add --no-cache git sed

ARG SOURCE_REPO=https://github.com/aescoubas/kea-sync.git
ARG SOURCE_REF=main

WORKDIR /src
RUN git clone "${SOURCE_REPO}" . \
    && git checkout "${SOURCE_REF}"

# Remove local replace directives that reference the superproject layout
RUN sed -i '/^replace github.com\/openchami\/tokensmith\/middleware => \.\.\/\.\.\/shared\/ochami-tokensmith\/middleware$/d' go.mod

RUN go build -o /out/kea-sync ./cmd/kea-sync

# ---------- runtime ----------
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache bash curl ca-certificates

COPY --from=builder /out/kea-sync /usr/local/bin/kea-sync

CMD ["kea-sync"]
