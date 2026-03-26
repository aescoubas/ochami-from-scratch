# TFTP server OCI image
#
# Build:
#   buildah bud -t localhost/tftp:latest images/tftp/
#
FROM alpine:3.18.12

RUN apk add --no-cache tftp-hpa bash coreutils

RUN mkdir -p /srv/tftp

EXPOSE 69/udp

CMD ["in.tftpd", "--foreground", "--user", "nobody", "--secure", "/srv/tftp"]
