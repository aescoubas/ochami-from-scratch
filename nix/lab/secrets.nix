# Deterministic test secrets for the NixOS VM lab.
# These are NOT for production — they are fixed values for reproducible testing.
{ pkgs }:

pkgs.writeText "secrets.env" ''
  POSTGRES_PASSWORD=test-postgres-password
  SMD_DB_PASSWORD=test-smd-password
  BSS_DB_PASSWORD=test-bss-password
  KEA_DB_PASSWORD=test-kea-password
  PCS_DB_PASSWORD=test-pcs-password
  STORK_DB_PASSWORD=test-stork-password
''
