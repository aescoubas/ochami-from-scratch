ARG BASE_IMAGE=nginx:1.27.5-alpine
FROM ${BASE_IMAGE}

# The build artifacts will be mounted here
# See k8s/http-server.yaml
COPY artifacts /usr/share/nginx/html/artifacts
RUN chmod -R +r /usr/share/nginx/html/artifacts

EXPOSE 80
