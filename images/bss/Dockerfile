# BSS (Boot Script Service) OCI image
#
# Build:
#   buildah bud --build-arg SOURCE_REF=v1.32.2 -t localhost/bss:v1.32.2 images/bss/
#
ARG GO_VERSION=1.24
ARG ALPINE_VERSION=3.20

# ---------- builder ----------
FROM golang:${GO_VERSION}-alpine AS builder

RUN apk add --no-cache git

ARG SOURCE_REPO=https://github.com/openchami/bss.git
ARG SOURCE_REF=main

WORKDIR /src
RUN git clone "${SOURCE_REPO}" . \
    && git checkout "${SOURCE_REF}"

RUN go build -o /out/boot-script-service  ./cmd/boot-script-service \
    && go build -o /out/bss-init           ./cmd/bss-init

# Copy migrations for the runtime image
RUN cp -r /src/migrations /out/migrations

# ---------- runtime ----------
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache bash curl ca-certificates

COPY --from=builder /out/boot-script-service  /usr/local/bin/boot-script-service
COPY --from=builder /out/bss-init             /usr/local/bin/bss-init
COPY --from=builder /out/migrations           /migrations/

CMD ["boot-script-service"]
