# Nginx reverse proxy + boot.ipxe artifact.
{ lib, defaults, hostIP, enableStork ? false, bootArtifacts }:

let
  httpPort = toString defaults.ports.http;
  bssPort = toString defaults.ports.bss;
  smdPort = toString defaults.ports.smd;
  ciPort = toString defaults.ports.cloudInit;
  pcsPort = toString defaults.ports.pcs;
  storkPort = toString defaults.ports.stork;
  nginxMainConf = ''
    worker_processes auto;
    error_log /dev/stderr info;
    pid /tmp/nginx.pid;

    events {
        worker_connections 1024;
    }

    http {
        access_log /dev/stdout;
        include ${defaults.containerPaths.nginxMimeTypes};
        default_type application/octet-stream;
        sendfile on;
        keepalive_timeout 65;
        client_body_temp_path /tmp/nginx_client_body;
        proxy_temp_path /tmp/nginx_proxy;
        fastcgi_temp_path /tmp/nginx_fastcgi;
        uwsgi_temp_path /tmp/nginx_uwsgi;
        scgi_temp_path /tmp/nginx_scgi;
        include /etc/nginx/conf.d/*.conf;
    }
  '';

  nginxConf = ''
    server {
        listen       ${httpPort};
        listen  [::]:${httpPort};
        server_name  localhost;

        location /apis/bss/ {
            rewrite ^/apis/bss/(.*)$ /$1 break;
            proxy_pass http://localhost:${bssPort};
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /boot/v1/ {
            proxy_pass http://localhost:${bssPort}/boot/v1/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }

        location /hsm/ {
            proxy_pass https://localhost:${smdPort};
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_ssl_verify off;
        }

        location /cloud-init/ {
            proxy_pass http://localhost:${ciPort}/cloud-init/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /power-control/ {
            proxy_pass http://localhost:${pcsPort}/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

    ${lib.optionalString enableStork ''
        location /stork/ {
            proxy_pass http://localhost:${storkPort}/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /api/ {
            proxy_pass http://localhost:${storkPort}/api/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    ''}
        location /hmi/v1/subscribe {
            return 200 '{"Components":[]}';
            add_header Content-Type application/json;
        }

        location / {
            root   /usr/share/nginx/html;
            index  index.html index.htm;
            autoindex on;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   /usr/share/nginx/html;
        }
    }
  '';

  bootIpxe = ''
    #!ipxe

    echo "=============================================="
    echo "OpenCHAMI Network Boot"
    echo "Server: ${hostIP}:${httpPort}"
    echo "=============================================="

    set base-url http://${hostIP}:${httpPort}

    echo "Loading kernel..."
    kernel ''${base-url}/${bootArtifacts.relativeDir}/${bootArtifacts.kernelFile} ${bootArtifacts.kernelArgs}

    echo "Loading initramfs..."
    initrd ''${base-url}/${bootArtifacts.relativeDir}/${bootArtifacts.initrdFile}

    echo "Booting..."
    boot
  '';
in
{
  service = {
    name = "http-server";
    image = defaults.images.nginx;
    volumes = [
      "./artifacts:/usr/share/nginx/html/artifacts:ro"
    ] ++ [
      "nginx.conf:/etc/nginx/nginx.conf:ro"
      "nginx-default.conf:/etc/nginx/conf.d/default.conf:ro"
      "boot.ipxe:/usr/share/nginx/html/boot.ipxe:ro"
    ];
    after = [ ];
    healthCheck = "bash -ec ': >/dev/tcp/127.0.0.1/${httpPort}'";
    type = "service";
  };

  configFiles = {
    "nginx.conf" = nginxMainConf;
    "nginx-default.conf" = nginxConf;
    "boot.ipxe" = bootIpxe;
  };

  # Boot artifacts are external — not bundled in generated output.
  # Deploy scripts must place kernel + initrd in the artifacts/ directory.
  inherit bootArtifacts;
}
