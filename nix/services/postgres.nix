# PostgreSQL service with multi-database init script.
{ pkgs, defaults }:

let
  # Generate the init script that creates all databases, users, and pgcrypto.
  initScript = pkgs.writeScript "postgres-init-db.sh" ''
    #!/bin/bash
    set -eu

    create_user_and_database() {
      local database="$1" username="$2" password="$3"
      echo "  Creating user '$username' and database '$database'"
      psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
        CREATE USER "$username" WITH PASSWORD '$password';
        CREATE DATABASE "$database";
        GRANT ALL PRIVILEGES ON DATABASE "$database" TO "$username";
    EOSQL
      psql -v ON_ERROR_STOP=0 --username "$POSTGRES_USER" -d "$database" <<-EOSQL
        CREATE EXTENSION IF NOT EXISTS pgcrypto;
    EOSQL
    }

    ${builtins.concatStringsSep "\n" (map (db:
      ''create_user_and_database "${db.name}" "${db.user}" "''$${db.passwordEnv}"''
    ) defaults.databases.entries)}

    echo "All databases created."
  '';
in
{
  service = {
    name = "postgres";
    image = defaults.images.postgres;
    command = "postgres -p ${toString defaults.ports.postgres}";
    environment = {
      POSTGRES_USER = defaults.databases.superuser;
    };
    volumes = [
      "${initScript}:/docker-entrypoint-initdb.d/multi-psql-db.sh:ro"
      "ochami-postgres-data:/var/lib/postgresql/data"
    ];
    healthCheck = "pg_isready -U ${defaults.databases.superuser} -p ${toString defaults.ports.postgres}";
    after = [ ];
    type = "service";
  };
}
