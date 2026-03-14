# Build HTTP server (nginx) OCI image.
#
# Usage:
#   nix build .#oci-http-server
#   podman load < result
#
{ pkgs }:

pkgs.dockerTools.buildLayeredImage {
  name = "localhost/http-server";
  tag = "latest";
  contents = [
    pkgs.nginx
    pkgs.coreutils
    pkgs.bash
  ];
  extraCommands = ''
    mkdir -p etc
    mkdir -p etc/nginx/conf.d
    mkdir -p usr/share/nginx/html
    mkdir -p var/log/nginx
    mkdir -p var/cache/nginx
    mkdir -p run
    mkdir -p tmp/nginx_client_body
    mkdir -p tmp/nginx_proxy
    mkdir -p tmp/nginx_fastcgi
    mkdir -p tmp/nginx_uwsgi
    mkdir -p tmp/nginx_scgi
    cat > etc/passwd <<'EOF'
    root:x:0:0:root:/root:/bin/sh
    nobody:x:65534:65534:nobody:/var/empty:/bin/sh
    EOF
    cat > etc/group <<'EOF'
    root:x:0:
    nogroup:x:65534:
    nobody:x:65534:
    EOF
  '';
  config = {
    Cmd = [ "${pkgs.nginx}/bin/nginx" "-c" "/etc/nginx/nginx.conf" "-g" "daemon off;" ];
    ExposedPorts = {
      "80/tcp" = { };
    };
  };
}
