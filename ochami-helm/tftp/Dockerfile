FROM alpine:3.19
RUN apk add --no-cache tftp-hpa
# Artifacts should be copied into this directory before build
COPY artifacts /var/tftpboot
RUN chmod -R +r /var/tftpboot
EXPOSE 69/udp
CMD ["in.tftpd", "-L", "--secure", "/var/tftpboot"]
