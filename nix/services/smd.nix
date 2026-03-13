# State Management Daemon (SMD) — init + long-running service.
{ defaults }:

let
  port = toString defaults.ports.postgres;
in
{
  init = {
    name = "smd-init";
    image = defaults.images.smd;
    command = "/bin/smd-init -migrationsdir /persistent_migrations/postgres";
    environment = {
      SMD_DBHOST = "localhost";
      SMD_DBPORT = port;
      SMD_DBNAME = "hmsds";
      SMD_DBUSER = "smd-user";
      SMD_DBOPTS = "sslmode=disable";
    };
    secretEnvKeys = [ "SMD_DB_PASSWORD" ];
    envMapping = { SMD_DBPASS = "SMD_DB_PASSWORD"; };
    after = [ "postgres" ];
    type = "oneshot";
  };

  service = {
    name = "smd";
    image = defaults.images.smd;
    environment = {
      SMD_DBHOST = "localhost";
      SMD_DBPORT = port;
      SMD_DBNAME = "hmsds";
      SMD_DBUSER = "smd-user";
      SMD_DBOPTS = "sslmode=disable";
      SMD_JWKS_URL = "";
    };
    secretEnvKeys = [ "SMD_DB_PASSWORD" ];
    envMapping = { SMD_DBPASS = "SMD_DB_PASSWORD"; };
    healthCheck = "curl -kfs https://localhost:${toString defaults.ports.smd}/hsm/v2/service/ready";
    after = [ "smd-init" ];
    type = "service";
  };
}
