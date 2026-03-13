# Cloud-init server.
{ defaults }:

let
  httpPort = toString defaults.ports.http;
  ciPort = toString defaults.ports.cloudInit;
  smdPort = toString defaults.ports.smd;
in
{
  service = {
    name = "cloud-init";
    image = defaults.images.cloudInit;
    command = "/bin/cloud-init-server --listen 0.0.0.0:${ciPort} --smd-url https://localhost:${smdPort} --cluster-name ochami --insecure";
    healthCheck = "bash -c 'exec 3<>/dev/tcp/127.0.0.1/${ciPort}'";
    after = [ "smd" ];
    type = "service";
  };
}
