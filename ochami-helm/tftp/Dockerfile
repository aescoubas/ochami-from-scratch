FROM alpine:3.18
RUN apk add --no-cache tftp-hpa
# Create directory for TFTP root
RUN mkdir -p /var/tftpboot
COPY artifacts/ /var/tftpboot/
# Expose standard TFTP port
EXPOSE 69/udp
# Start tftpd in foreground (-L), secure mode (-s)
CMD ["in.tftpd", "-L", "-s", "/var/tftpboot"]
