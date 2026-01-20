FROM alpine:3.19
RUN apk add --no-cache kea-dhcp4
RUN mkdir -p /var/lib/kea /var/run/kea
EXPOSE 67/udp
CMD ["kea-dhcp4", "-c", "/etc/kea/kea-dhcp4.conf"]
