import os
import socket
import libvirt
import json
import ssl
import threading
from http.server import HTTPServer, BaseHTTPRequestHandler
import xml.etree.ElementTree as ET

# Configuration
VM_NAME_PREFIX = os.environ.get("VM_NAME_PREFIX", "virtual-compute-node-")
# VM_INDEX env var overrides hostname-based detection (needed for podman host networking
# where the container inherits the host's hostname instead of a StatefulSet pod name)
if os.environ.get("VM_INDEX") is not None:
    INDEX = int(os.environ["VM_INDEX"])
else:
    # Hostname expected format: ochami-redfish-emulator-0 -> index 0
    HOSTNAME = socket.gethostname()
    try:
        INDEX = int(HOSTNAME.split("-")[-1])
    except Exception as e:
        print(f"Warning: Could not determine index from hostname {HOSTNAME}, defaulting to 0. Error: {e}")
        INDEX = 0

VM_NAME = f"{VM_NAME_PREFIX}{INDEX}"
print(f"Emulator for VM: {VM_NAME}")

def get_libvirt_conn():
    try:
        # Connect to the mounted libvirt socket
        # In the container, we expect the socket at /var/run/libvirt/libvirt-sock
        # which corresponds to qemu:///system
        conn = libvirt.open("qemu:///system")
        return conn
    except Exception as e:
        print(f"Failed to connect to libvirt: {e}")
        return None

def get_vm_info():
    conn = get_libvirt_conn()
    if not conn:
        return {"State": "Absent", "MAC": "00:00:00:00:00:00"}
    
    try:
        dom = conn.lookupByName(VM_NAME)
        state, _ = dom.state()
        # VIR_DOMAIN_RUNNING = 1
        power_state = "On" if state == 1 else "Off"
        
        # Get MAC address from XML
        raw_xml = dom.XMLDesc(0)
        root = ET.fromstring(raw_xml)
        # Find interface with source network='pxe-net' or bridge='virbr-pxe'
        # Simplified: just take the first interface's mac
        mac = "00:00:00:00:00:00"
        for interface in root.findall("./devices/interface"):
            mac_elem = interface.find("mac")
            if mac_elem is not None:
                mac = mac_elem.get("address")
                break
        
        return {"State": power_state, "MAC": mac}
    except libvirt.libvirtError:
        return {"State": "Absent", "MAC": "00:00:00:00:00:00"}
    finally:
        conn.close()

def set_vm_power(action):
    conn = get_libvirt_conn()
    if not conn:
        return False
    
    try:
        dom = conn.lookupByName(VM_NAME)
        state, _ = dom.state()
        is_running = (state == 1)
        
        if action == "On":
            if not is_running:
                dom.create()
        elif action == "ForceOff":
            if is_running:
                dom.destroy()
        elif action == "GracefulRestart":
            if is_running:
                dom.reboot()
        
        return True
    except libvirt.libvirtError as e:
        print(f"Libvirt error during {action}: {e}")
        return False
    finally:
        conn.close()

class RedfishHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.rstrip("/")
        
        if path == "/redfish/v1" or path == "/redfish/v1/":
            self.send_json({
                "Systems": {"@odata.id": "/redfish/v1/Systems"},
                "Chassis": {"@odata.id": "/redfish/v1/Chassis"},
                "Managers": {"@odata.id": "/redfish/v1/Managers"}
            })
        elif path == "/redfish/v1/Systems":
            self.send_json({"Members": [{"@odata.id": "/redfish/v1/Systems/1"}]})
        elif path == "/redfish/v1/Systems/1":
            info = get_vm_info()
            self.send_json({
                "@odata.id": "/redfish/v1/Systems/1",
                "Id": "1",
                "Name": VM_NAME,
                "PowerState": info["State"],
                "ProcessorSummary": {
                    "Count": 1,
                    "Model": "Virtual CPU"
                },
                "MemorySummary": {
                    "TotalSystemMemoryGiB": 8,
                    "Status": {"State": "Enabled", "Health": "OK"}
                },
                "Processors": {"@odata.id": "/redfish/v1/Systems/1/Processors"},
                "EthernetInterfaces": {"@odata.id": "/redfish/v1/Systems/1/EthernetInterfaces"},
                "Actions": {
                    "#ComputerSystem.Reset": {
                        "target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
                        "ResetType@Redfish.AllowableValues": ["On", "ForceOff", "GracefulRestart"]
                    }
                }
            })
        elif path == "/redfish/v1/Systems/1/Processors":
             self.send_json({"Members": [{"@odata.id": "/redfish/v1/Systems/1/Processors/1"}]})
        elif path == "/redfish/v1/Systems/1/Processors/1":
            self.send_json({
                "@odata.id": "/redfish/v1/Systems/1/Processors/1",
                "Id": "1",
                "Name": "Processor 1",
                "Socket": "CPU 1",
                "ProcessorType": "CPU",
                "ProcessorArchitecture": "x86",
                "InstructionSet": "x86-64",
                "TotalCores": 4
            })
        elif path == "/redfish/v1/Systems/1/EthernetInterfaces":
             self.send_json({"Members": [{"@odata.id": "/redfish/v1/Systems/1/EthernetInterfaces/1"}]})
        elif path == "/redfish/v1/Systems/1/EthernetInterfaces/1":
            info = get_vm_info()
            self.send_json({
                "@odata.id": "/redfish/v1/Systems/1/EthernetInterfaces/1",
                "MACAddress": info["MAC"]
            })
        elif path == "/redfish/v1/Chassis":
            self.send_json({"Members": [{"@odata.id": "/redfish/v1/Chassis/1"}]})
        elif path == "/redfish/v1/Chassis/1":
            self.send_json({
                "@odata.id": "/redfish/v1/Chassis/1",
                "Id": "1",
                "Name": "Chassis 1",
                "PowerState": "On"
            })
        elif path == "/redfish/v1/Managers":
            self.send_json({"Members": [{"@odata.id": "/redfish/v1/Managers/1"}]})
        elif path == "/redfish/v1/Managers/1":
            self.send_json({
                "@odata.id": "/redfish/v1/Managers/1",
                "Id": "1",
                "Name": "Manager 1",
                "ManagerType": "BMC",
                "EthernetInterfaces": {"@odata.id": "/redfish/v1/Managers/1/EthernetInterfaces"}
            })
        elif path == "/redfish/v1/Managers/1/EthernetInterfaces":
             self.send_json({"Members": []})
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        path = self.path.rstrip("/")
        if path == "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset":
            length = int(self.headers.get('content-length', 0))
            if length > 0:
                body = self.rfile.read(length)
                try:
                    data = json.loads(body)
                    reset_type = data.get("ResetType")
                    if reset_type in ["On", "ForceOff", "GracefulRestart"]:
                        success = set_vm_power(reset_type)
                        if success:
                            self.send_response(200) # Or 204 No Content
                            self.end_headers()
                            self.wfile.write(b'{}')
                        else:
                            self.send_error(500, "Failed to execute power action")
                    else:
                        self.send_error(400, "Invalid ResetType")
                except json.JSONDecodeError:
                    self.send_error(400, "Invalid JSON")
            else:
                self.send_error(400, "Missing body")
        else:
            self.send_response(404)
            self.end_headers()

    def send_json(self, data):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())
    
    def log_message(self, format, *args):
        # Silence logs to stdout to avoid clutter, or redirect to stderr
        pass

def run_server():
    # Run HTTPS on 443
    # Use self-signed cert
    # For now, let's generate a dummy cert at startup if not exists
    if not os.path.exists("/tmp/server.key"):
        os.system("openssl req -new -newkey rsa:2048 -days 365 -nodes -x509 -keyout /tmp/server.key -out /tmp/server.crt -subj '/CN=localhost'")

    try:
        httpd = HTTPServer(('0.0.0.0', 443), RedfishHandler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certfile='/tmp/server.crt', keyfile='/tmp/server.key')
        httpd.socket = context.wrap_socket(httpd.socket, server_side=True)
        print("Starting Redfish Emulator on :443")
        httpd.serve_forever()
    except Exception as e:
        print(f"Server failed: {e}")

if __name__ == "__main__":
    run_server()
