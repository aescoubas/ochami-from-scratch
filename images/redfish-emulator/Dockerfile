# Redfish emulator OCI image (lightweight per-VM emulator)
#
# Build:
#   buildah bud -t localhost/redfish-emulator:latest images/redfish-emulator/
#
ARG BASE_IMAGE=python:3.9.21-slim-bookworm
FROM ${BASE_IMAGE}

RUN apt-get update && apt-get install -y --no-install-recommends \
        libvirt-dev \
        gcc \
        python3-dev \
        pkg-config \
        openssl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir libvirt-python

COPY emulator.py /emulator.py

CMD ["python", "-u", "/emulator.py"]
