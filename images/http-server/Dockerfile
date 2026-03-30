# HTTP server (nginx) OCI image for serving boot artifacts
#
# Build:
#   buildah bud -t localhost/http-server:latest images/http-server/
#
FROM nginx:1.27.5-alpine

RUN mkdir -p /etc/nginx/conf.d \
             /usr/share/nginx/html \
             /var/log/nginx \
             /var/cache/nginx \
             /tmp/nginx_client_body \
             /tmp/nginx_proxy \
             /tmp/nginx_fastcgi \
             /tmp/nginx_uwsgi \
             /tmp/nginx_scgi

EXPOSE 80/tcp

CMD ["nginx", "-c", "/etc/nginx/nginx.conf", "-g", "daemon off;"]
