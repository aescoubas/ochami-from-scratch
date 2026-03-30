# libvirt-bmc OCI image (sushy-tools based Redfish BMC emulator)
#
# Build:
#   buildah bud -t localhost/libvirt-bmc:latest images/libvirt-bmc/
#
FROM python:3.11-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
        libvirt-dev \
        gcc \
        python3-dev \
        pkg-config \
        openssl \
        ca-certificates \
        coreutils \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
        sushy-tools==2.2.0 \
        bcrypt \
        flask \
        libvirt-python \
        pbr \
        requests \
        tenacity \
        webob

COPY app.py /app/app.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

CMD ["/app/entrypoint.sh"]
