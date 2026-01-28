FROM python:3.9-slim

# Install libvirt client libraries and openssl for cert generation
RUN apt-get update && apt-get install -y \
    libvirt-dev \
    gcc \
    pkg-config \
    openssl \
    && rm -rf /var/lib/apt/lists/*

# Install python dependencies
RUN pip install libvirt-python

COPY emulator.py /emulator.py

CMD ["python", "-u", "/emulator.py"]

