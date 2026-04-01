# Cloud-Init Configuration

This directory contains the cloud-init data pushed to the OpenCHAMI cloud-init
metadata service (port 27777). The service stores data in memory — it must be
repopulated after any service restart.

## Files

| File | Purpose |
|------|---------|
| `cluster-defaults.json` | Cluster-wide metadata (cloud-provider, cluster-name) |
| `compute.yaml` | Cloud-config for the `compute` group (DNS, packages, zypper GPG keys) |

## Usage

See the main README section "Configure cloud-init metadata" for the full
walkthrough, or use the quick commands below.

### Push all configuration

```bash
# 1. Set cluster defaults
curl -X POST http://localhost:27777/admin/cluster-defaults \
  -H 'Content-Type: application/json' \
  -d @cloud-init/cluster-defaults.json

# 2. Create or update the compute group
CLOUD_CONFIG=$(base64 -w0 < cloud-init/compute.yaml)
curl -X POST http://localhost:27777/admin/groups \
  -H 'Content-Type: application/json' \
  -d "{\"name\": \"compute\", \"description\": \"Compute nodes\", \"data\": {}, \"file\": {\"content\": \"${CLOUD_CONFIG}\", \"encoding\": \"base64\"}}"

# 3. Set per-node instance info (hostname)
curl -X PUT http://localhost:27777/admin/instance-info/<XNAME> \
  -H 'Content-Type: application/json' \
  -d '{"local-hostname": "<HOSTNAME>", "hostname": "<HOSTNAME>"}'
```

### Verify

```bash
curl -s http://localhost:27777/admin/impersonation/<XNAME>/meta-data
curl -s http://localhost:27777/admin/impersonation/<XNAME>/user-data
curl -s http://localhost:27777/admin/impersonation/<XNAME>/vendor-data
curl -s http://localhost:27777/admin/impersonation/<XNAME>/compute.yaml
```
