ARG BASE_IMAGE=python:3.9.21-slim-bookworm
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

COPY smd_sync.py /app/smd_sync.py

CMD ["python", "-u", "/app/smd_sync.py"]
