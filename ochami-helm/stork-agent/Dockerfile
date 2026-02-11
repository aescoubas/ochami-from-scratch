FROM jonasal/kea-dhcp4:3.1.4
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/isc/stork/setup.deb.sh' | bash && \
    apt-get install -y --no-install-recommends isc-stork-agent && \
    apt-get clean && rm -rf /var/lib/apt/lists/*
EXPOSE 28011
ENV STORK_AGENT_PORT=28011
ENTRYPOINT []
CMD ["stork-agent"]
