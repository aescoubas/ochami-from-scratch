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
