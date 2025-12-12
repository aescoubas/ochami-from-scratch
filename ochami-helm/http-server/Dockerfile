FROM nginx:alpine

# The build artifacts will be mounted here
# See k8s/http-server.yaml
COPY artifacts /usr/share/nginx/html/artifacts
RUN chmod -R +r /usr/share/nginx/html/artifacts

EXPOSE 80
