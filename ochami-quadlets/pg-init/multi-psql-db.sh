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

create_user_and_database "hmsds" "smd-user" "$SMD_DB_PASSWORD"
create_user_and_database "bssdb" "bss-user" "$BSS_DB_PASSWORD"
create_user_and_database "kea" "kea-user" "$KEA_DB_PASSWORD"
create_user_and_database "pcsdb" "pcs-user" "$PCS_DB_PASSWORD"
create_user_and_database "stork" "stork-user" "$STORK_DB_PASSWORD"

echo "All databases created."
