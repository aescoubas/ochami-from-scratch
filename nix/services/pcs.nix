# Power Control Service (PCS) — init + long-running service.
{ defaults }:

let
  pgPort = toString defaults.ports.postgres;
  httpPort = toString defaults.ports.http;
in
{
  init = {
    name = "pcs-init";
    image = defaults.images.pcs;
    command = "power-control init-postgres";
    environment = {
      POSTGRES_HOST = "localhost";
      POSTGRES_PORT = pgPort;
      POSTGRES_USER = "pcs-user";
      POSTGRES_DBNAME = "pcsdb";
      POSTGRES_INSECURE = "true";
    };
    secretEnvKeys = [ "PCS_DB_PASSWORD" ];
    envMapping = { POSTGRES_PASSWORD = "PCS_DB_PASSWORD"; };
    after = [ "postgres" ];
    type = "oneshot";
  };

  service = {
    name = "pcs";
    image = defaults.images.pcs;
    command = "power-control --run-control";
    environment = {
      STORAGE = "POSTGRES";
      SMS_SERVER = "http://localhost:${httpPort}";
      POSTGRES_HOST = "localhost";
      POSTGRES_PORT = pgPort;
      POSTGRES_USER = "pcs-user";
      POSTGRES_DBNAME = "pcsdb";
      POSTGRES_INSECURE = "true";
      TRS_IMPLEMENTATION = "LOCAL";
      HSMLOCK_ENABLED = "true";
      VAULT_ENABLED = "false";
      FAKE_VAULT_ENABLED = "false";
      LOG_LEVEL = "INFO";
    };
    secretEnvKeys = [ "PCS_DB_PASSWORD" ];
    envMapping = { POSTGRES_PASSWORD = "PCS_DB_PASSWORD"; };
    after = [ "smd" "pcs-init" ];
    type = "service";
  };
}
