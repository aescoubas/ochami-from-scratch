# Abstract: Accelerating HPC Control Plane Development

**Title:** Accelerating HPC Control Plane Development: Deploying OpenCHAMI Test Systems from Local VMs to Bare Metal

**Abstract:**

OpenCHAMI, the open-source successor to the Cray System Management (CSM) stack, reimagines HPC system management through a modular, microservices-based architecture. While this shift offers flexibility, it introduces complexity in replicating the environment for development and testing. To address this, we present a versatile tooling suite designed to **empower developers by tightening the feedback loop**, enabling the deployment of full-featured OpenCHAMI control planes on commodity workstations.

This presentation explores three distinct deployment workflows tailored to different stages of the development lifecycle:
1.  **Minikube-based Simulation:** A self-contained environment using Libvirt to model an entire cluster—including virtual compute nodes and emulated Redfish BMCs—on a single laptop.
2.  **Docker Compose Quickstart:** A rapid instantiation method for stand-alone service testing.
3.  **Podman Quadlets:** A systemd-integrated approach for robust, production-like service management.

Crucially, we demonstrate how this setup is not limited to simulation but is capable of **booting and provisioning physical hardware nodes** directly from a developer's machine. Key DevOps discussions will cover the "Sidecar" pattern for synchronizing DHCP and State Management Database (SMD) state, the automation of custom boot image generation, and the orchestration of network services to handle hybrid virtual/physical environments. By democratizing access to complex infrastructure, these tools allow contributors to validate code changes instantly, accelerating the evolution of the next generation of HPC system management.
