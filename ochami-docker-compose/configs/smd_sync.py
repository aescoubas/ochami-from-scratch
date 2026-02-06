import psycopg2
import requests
import time
import os
import socket
import struct

SMD_URL = os.environ.get("SMD_URL")
DB_NAME = os.environ.get("DB_NAME")
DB_USER = os.environ.get("DB_USER")
DB_PASS = os.environ.get("DB_PASS")
DB_HOST = os.environ.get("DB_HOST")
DB_PORT = os.environ.get("DB_PORT")

def get_db_connection():
    return psycopg2.connect(
        dbname=DB_NAME,
        user=DB_USER,
        password=DB_PASS,
        host=DB_HOST,
        port=DB_PORT
    )

def mac_to_bytes(mac_str):
    clean_mac = mac_str.replace(":", "").replace("-", "")
    return bytes.fromhex(clean_mac)

def ip_to_int(ip_str):
    return struct.unpack("!I", socket.inet_aton(ip_str))[0]

def sync_hosts():
    conn = None
    try:
        print(f"Connecting to DB {DB_HOST}...")
        conn = get_db_connection()
        cur = conn.cursor()

        print(f"Fetching interfaces from {SMD_URL}...")
        try:
            resp = requests.get(f"{SMD_URL}/hsm/v2/Inventory/EthernetInterfaces", timeout=5)
            if resp.status_code != 200:
                print(f"Error fetching SMD: {resp.status_code}")
                return
            interfaces = resp.json()
        except Exception as e:
            print(f"Failed to query SMD: {e}")
            return

        for iface in interfaces:
            mac = iface.get('MACAddress')
            ips = iface.get('IPAddresses', [])
            comp_id = iface.get('ComponentID')

            if not mac or not ips:
                continue

            ip_addr = ips[0].get('IPAddress')
            if not ip_addr:
                continue

            mac_bytes = mac_to_bytes(mac)
            try:
                ip_int = ip_to_int(ip_addr)
            except:
                print(f"Invalid IP: {ip_addr}")
                continue

            # Upsert into Kea hosts table
            # dhcp_identifier_type = 0 (hw-address)
            # dhcp4_subnet_id = 1 (our subnet)

            # Check if host exists
            cur.execute("SELECT host_id FROM hosts WHERE dhcp_identifier = %s", (mac_bytes,))
            res = cur.fetchone()

            if res:
                # Update
                cur.execute("""
                    UPDATE hosts SET ipv4_address = %s, hostname = %s
                    WHERE host_id = %s
                """, (ip_int, comp_id, res[0]))
            else:
                # Insert
                print(f"Inserting new host {mac} -> {ip_addr}")
                cur.execute("""
                    INSERT INTO hosts (dhcp_identifier, dhcp_identifier_type, dhcp4_subnet_id, ipv4_address, hostname)
                    VALUES (%s, 0, 1, %s, %s)
                """, (mac_bytes, ip_int, comp_id))

        conn.commit()
        cur.close()
    except Exception as e:
        print(f"Sync error: {e}")
    finally:
        if conn:
            conn.close()

print("Starting SMD Sync Sidecar...")
while True:
    sync_hosts()
    time.sleep(10)
