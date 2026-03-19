# Build a per-VM libvirt-backed Redfish BMC image with sushy-tools.
#
# Usage:
#   nix build .#oci-libvirt-bmc
#   podman load < result
#
{ pkgs
, imageTag ? "latest"
}:

let
  sushyRuntimeDeps = with pkgs.python3Packages; [
    bcrypt
    flask
    libvirt
    pbr
    requests
    tenacity
    webob
  ];

  runtimePython = pkgs.python3.withPackages (_: sushyRuntimeDeps);

  sushyTools = pkgs.python3Packages.buildPythonApplication rec {
    pname = "sushy-tools";
    version = "2.2.0";
    pyproject = true;

    src = pkgs.fetchPypi {
      pname = "sushy_tools";
      inherit version;
      hash = "sha256-tWLvjyoI4Up9fR3V0iEByzZlIHbOiXi9B3TKGjaOrag=";
    };

    nativeBuildInputs = with pkgs.python3Packages; [
      pbr
      setuptools
    ];

    propagatedBuildInputs = sushyRuntimeDeps;

    doCheck = false;
    pythonImportsCheck = [ "sushy_tools" ];
  };

  pythonPath = "${sushyTools}/${pkgs.python3.sitePackages}:${pkgs.python3Packages.makePythonPath sushyRuntimeDeps}";

  appWrapper = pkgs.writeText "libvirt-bmc-app.py" ''
    import os

    from sushy_tools import error
    from sushy_tools.emulator import api_utils
    from sushy_tools.emulator.main import app, jsonify


    @app.route("/redfish/v1/Systems/<identity>/Memory", methods=["GET"])
    @api_utils.ensure_instance_access
    @api_utils.returns_json
    def memory_collection_resource(identity):
        if app.feature_set != "full":
            raise error.FeatureNotAvailable("Memory")

        app.systems.uuid(identity)
        return jsonify(
            "MemoryCollection",
            "v1_1_0",
            {
                "Name": "Memory Module Collection",
                "Description": "Memory Module Collection",
                "Members@odata.count": 0,
                "Members": [],
                "@odata.id": f"/redfish/v1/Systems/{identity}/Memory",
            },
        )


    @app.route("/redfish/v1/Systems/<identity>/Memory/<memory_id>", methods=["GET"])
    @api_utils.ensure_instance_access
    @api_utils.returns_json
    def memory_resource(identity, memory_id):
        if app.feature_set != "full":
            raise error.FeatureNotAvailable("Memory")
        raise error.NotFound()


    def patch_storage_driver():
        storage_driver = app.storage
        original_get_storage_col = storage_driver.get_storage_col

        def safe_get_storage_col(identity):
            try:
                return original_get_storage_col(identity)
            except Exception:
                app.logger.warning(
                    "Falling back to an empty Storage collection for %s",
                    identity,
                    exc_info=True,
                )
                return []

        storage_driver.get_storage_col = safe_get_storage_col


    def main():
        app.configure(
            extra_config={
                "SUSHY_EMULATOR_LIBVIRT_URI": os.environ.get(
                    "SUSHY_EMULATOR_LIBVIRT_URI", "qemu:///system"
                ),
            }
        )
        patch_storage_driver()
        app.run(
            host=os.environ.get("SUSHY_EMULATOR_LISTEN_IP", "0.0.0.0"),
            port=int(os.environ.get("SUSHY_EMULATOR_LISTEN_PORT", "443")),
            ssl_context=(
                os.environ["SUSHY_EMULATOR_SSL_CERT"],
                os.environ["SUSHY_EMULATOR_SSL_KEY"],
            ),
            debug=False,
            use_reloader=False,
        )


    if __name__ == "__main__":
        main()
  '';

  entrypoint = pkgs.writeShellScriptBin "libvirt-bmc-entrypoint" ''
    set -euo pipefail

    work_dir="''${SUSHY_EMULATOR_WORK_DIR:-/tmp/sushy-emulator}"
    state_dir="''${SUSHY_EMULATOR_STATE_DIR:-''${work_dir}/state}"
    config_file="''${work_dir}/emulator.conf.py"
    auth_file="''${SUSHY_EMULATOR_AUTH_FILE:-''${work_dir}/auth.htpasswd}"
    cert_file="''${SUSHY_EMULATOR_SSL_CERT:-''${work_dir}/tls.crt}"
    key_file="''${SUSHY_EMULATOR_SSL_KEY:-''${work_dir}/tls.key}"

    export PYTHONNOUSERSITE=true
    export PYTHONPATH="${pythonPath}''${PYTHONPATH:+:$PYTHONPATH}"

    mkdir -p "$work_dir" "$state_dir"
    rm -f "$config_file"

    if [ ! -f "$cert_file" ] || [ ! -f "$key_file" ]; then
      mkdir -p "$(dirname "$cert_file")" "$(dirname "$key_file")"
      ${pkgs.openssl}/bin/openssl req \
        -x509 \
        -newkey rsa:2048 \
        -nodes \
        -days 365 \
        -subj "/CN=''${SUSHY_EMULATOR_SSL_COMMON_NAME:-localhost}" \
        -keyout "$key_file" \
        -out "$cert_file" \
        >/dev/null 2>&1
    fi

    export SUSHY_EMULATOR_SSL_CERT="$cert_file"
    export SUSHY_EMULATOR_SSL_KEY="$key_file"

    ${runtimePython}/bin/python - "$auth_file" <<'PY'
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

    ${runtimePython}/bin/python - "$config_file" "$auth_file" "$state_dir" <<'PY'
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

    exec ${runtimePython}/bin/python ${appWrapper}
  '';
in
pkgs.dockerTools.buildLayeredImage {
  name = "localhost/libvirt-bmc";
  tag = imageTag;
  contents = [
    entrypoint
    runtimePython
    sushyTools
    pkgs.cacert
    pkgs.coreutils
    pkgs.openssl
  ];
  config = {
    Cmd = [ "${entrypoint}/bin/libvirt-bmc-entrypoint" ];
  };
}
