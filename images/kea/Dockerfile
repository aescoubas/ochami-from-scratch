# Kea DHCP server OCI image
#
# Build:
#   buildah bud -t localhost/kea:latest images/kea/
#
# Uses the upstream jonasal/kea-dhcp4 image which includes the DHCPv4 server,
# kea-admin, and hook libraries at /usr/lib/x86_64-linux-gnu/kea/hooks.
#
FROM jonasal/kea-dhcp4:3.1.4

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        postgresql-client \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /etc/kea /run/kea /var/lib/kea /var/run/kea

EXPOSE 67/udp
EXPOSE 8000/tcp

CMD ["/usr/sbin/kea-dhcp4", "-c", "/etc/kea/kea-dhcp4.conf"]
