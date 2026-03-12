# Cloud-init server.
{ defaults }:

let
  httpPort = toString defaults.ports.http;
  ciPort = toString defaults.ports.cloudInit;
in
{
  service = {
    name = "cloud-init";
    image = defaults.images.cloudInit;
    command = "/usr/local/bin/cloud-init-server --listen 0.0.0.0:${ciPort} --smd-url http://localhost:${httpPort} --cluster-name ochami --insecure";
    healthCheck = "ss -tlnp sport = :${ciPort} | grep -q ${ciPort}";
    after = [ "smd" ];
    type = "service";
  };
}
