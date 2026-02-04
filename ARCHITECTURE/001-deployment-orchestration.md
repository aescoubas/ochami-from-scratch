# ADR 001: Deployment Orchestration with Helm and Minikube

## Status
Accepted

## Context
The OpenCHAMI project requires a reliable and reproducible way to deploy its control plane services (SMD, BSS, DHCP, TFTP, etc.) for both development and testing environments. The system consists of multiple interdependent microservices that need to be orchestrated together. Developers need to simulate a full cluster environment, including networking and bare-metal booting, on their local machines.

## Decision
We decided to use **Helm** for managing the deployment of OpenCHAMI services and **Minikube** (specifically with the `none` driver) as the primary target for local simulation.

- **Helm:** Used to package the application as a chart (`ochami-helm`), managing templates for Pods, Services, ConfigMaps, and StatefulSets.
- **Minikube:** Used to run a single-node Kubernetes cluster locally. The `none` driver is chosen to allow direct access to the host's networking stack, which is crucial for DHCP and TFTP services to interact with external VMs or physical hardware.

## Consequences
### Positive
- **Unified Management:** Helm provides a single command to deploy or upgrade the entire stack.
- **Templating:** Allows flexible configuration (e.g., changing image tags, network settings) via `values.yaml`.
- **Production Parity:** Minikube provides a Kubernetes environment that closely mimics production, unlike simple process managers.
- **Networking:** The `none` driver simplifies the complex networking requirements of DHCP/PXE by removing the isolation layer of a VM-based Kubernetes node.

### Negative
- **Complexity:** Requires knowledge of Kubernetes and Helm.
- **Host Dependencies:** The `none` driver requires Docker and CNI plugins to be installed directly on the host system, potentially cluttering the developer's environment.
- **Privileges:** Running Minikube with the `none` driver requires `sudo` privileges.
