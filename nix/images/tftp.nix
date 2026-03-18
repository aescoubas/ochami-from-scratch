# Build TFTP server OCI image.
#
# Usage:
#   nix build .#oci-tftp
#   podman load < result
#
{ pkgs
, imageName ? "localhost/tftp"
, imageTag ? "latest"
}:

pkgs.dockerTools.buildLayeredImage {
  name = imageName;
  tag = imageTag;
  contents = [
    pkgs.tftp-hpa
    pkgs.coreutils
    pkgs.bash
  ];
  extraCommands = ''
    mkdir -p etc
    mkdir -p srv/tftp
    cat > etc/passwd <<'EOF'
    root:x:0:0:root:/root:/bin/sh
    nobody:x:65534:65534:nobody:/var/empty:/bin/sh
    EOF
    cat > etc/group <<'EOF'
    root:x:0:
    nobody:x:65534:
    EOF
  '';
  config = {
    Cmd = [ "${pkgs.tftp-hpa}/bin/in.tftpd" "--foreground" "--user" "nobody" "--secure" "/srv/tftp" ];
    ExposedPorts = {
      "69/udp" = { };
    };
  };
}
