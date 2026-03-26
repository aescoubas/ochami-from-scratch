#!/usr/bin/env bash
set -euo pipefail

work_dir="${SUSHY_EMULATOR_WORK_DIR:-/tmp/sushy-emulator}"
state_dir="${SUSHY_EMULATOR_STATE_DIR:-${work_dir}/state}"
config_file="${work_dir}/emulator.conf.py"
auth_file="${SUSHY_EMULATOR_AUTH_FILE:-${work_dir}/auth.htpasswd}"
cert_file="${SUSHY_EMULATOR_SSL_CERT:-${work_dir}/tls.crt}"
key_file="${SUSHY_EMULATOR_SSL_KEY:-${work_dir}/tls.key}"

mkdir -p "$work_dir" "$state_dir"
rm -f "$config_file"

if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
    mkdir -p "$(dirname "$cert_file")" "$(dirname "$key_file")"
    openssl req \
        -x509 \
        -newkey rsa:2048 \
        -nodes \
        -days 365 \
        -subj "/CN=${SUSHY_EMULATOR_SSL_COMMON_NAME:-localhost}" \
        -keyout "$key_file" \
        -out "$cert_file" \
        >/dev/null 2>&1
fi

export SUSHY_EMULATOR_SSL_CERT="$cert_file"
export SUSHY_EMULATOR_SSL_KEY="$key_file"

python - "$auth_file" <<'PY'
import os
import pathlib
import sys

import bcrypt

auth_path = pathlib.Path(sys.argv[1])
auth_path.parent.mkdir(parents=True, exist_ok=True)
username = os.environ.get("SUSHY_EMULATOR_USERNAME", "admin")
password = os.environ.get("SUSHY_EMULATOR_PASSWORD", "password").encode("utf-8")
auth_path.write_text(
    f"{username}:{bcrypt.hashpw(password, bcrypt.gensalt()).decode()}\n",
    encoding="utf-8",
)
PY

python - "$config_file" "$auth_file" "$state_dir" <<'PY'
import os
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
auth_file = sys.argv[2]
state_dir = sys.argv[3]
allowed = [
    item.strip()
    for item in os.environ.get("SUSHY_EMULATOR_ALLOWED_INSTANCES", "").split(",")
    if item.strip()
]
lines = [
    f"SUSHY_EMULATOR_AUTH_FILE = {auth_file!r}",
    f"SUSHY_EMULATOR_STATE_DIR = {state_dir!r}",
    f"SUSHY_EMULATOR_FEATURE_SET = {os.environ.get('SUSHY_EMULATOR_FEATURE_SET', 'full')!r}",
]

if allowed:
    lines.append(f"SUSHY_EMULATOR_ALLOWED_INSTANCES = {allowed!r}")

if os.environ.get("SUSHY_EMULATOR_DISABLE_POWER_OFF", "").lower() in {"1", "true", "yes"}:
    lines.append("SUSHY_EMULATOR_DISABLE_POWER_OFF = True")

config_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

export SUSHY_EMULATOR_CONFIG="$config_file"

exec python /app/app.py
