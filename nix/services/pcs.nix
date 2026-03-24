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
    command = "/bin/bash -c 'power-control init-postgres --postgres-insecure --postgres-host localhost --postgres-port ${pgPort} --postgres-user pcs-user --postgres-dbname pcsdb --postgres-password $PCS_DB_PASSWORD'";
    secretEnvKeys = [ "PCS_DB_PASSWORD" ];
    envMapping = { POSTGRES_PASSWORD = "PCS_DB_PASSWORD"; };
    after = [ "postgres" ];
    type = "oneshot";
  };

  service = {
    name = "pcs";
    image = defaults.images.pcs;
    command = "/bin/bash -c 'power-control --run-control --postgres-insecure --postgres-host localhost --postgres-port ${pgPort} --postgres-user pcs-user --postgres-dbname pcsdb --postgres-password $PCS_DB_PASSWORD'";
    environment = {
      STORAGE = "POSTGRES";
      SMS_SERVER = "http://localhost:${httpPort}";
      TRS_IMPLEMENTATION = "LOCAL";
      HSMLOCK_ENABLED = "true";
      VAULT_ENABLED = "false";
      FAKE_VAULT_ENABLED = "true";
      LOG_LEVEL = "INFO";
    };
    secretEnvKeys = [ "PCS_DB_PASSWORD" ];
    envMapping = {
      PCS_FAKE_VAULT_REDFISH_USER = "LIBVIRT_BMC_USER";
      PCS_FAKE_VAULT_REDFISH_PASSWORD = "LIBVIRT_BMC_PASSWORD";
    };
    after = [ "smd" "pcs-init" ];
    type = "service";
  };
}
