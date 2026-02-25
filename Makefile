.PHONY: test test-vm test-vm-ubuntu test-vm-fedora test-vm-destroy

test:
	bash scripts/tests/test_roadmap_process.sh
	bash scripts/tests/test_common_args.sh
	bash scripts/tests/test_build_microservices.sh
	bash scripts/tests/test_magellan_discovery.sh
	bash scripts/tests/test_reverse_proxy_routing.sh
	bash scripts/tests/test_image_base_standardization.sh
	bash scripts/tests/test_kea_sidecar_runtime.sh
	bash scripts/tests/test_build_artifact_extraction.sh
	bash scripts/tests/test_emulator_mount_behavior.sh
	bash scripts/tests/test_registration_contract_consistency.sh
	bash scripts/tests/test_deploy_policies_and_dedup.sh
	bash scripts/tests/test_deploy_pipeline_dedup.sh
	bash scripts/tests/test_runtime_config_generation_shared.sh
	bash scripts/tests/test_helm_termination_grace_policy.sh
	bash scripts/tests/test_prereq_sysctl_policy.sh
	bash scripts/tests/test_libvirt_deploy_smoke_coverage.sh
	bash scripts/tests/test_vm_runner_prereq_and_paths.sh
	python3 scripts/tests/test_openchami_mcp.py
	bash scripts/tests/test_mcp_minikube_integration.sh

test-vm: test-vm-ubuntu test-vm-fedora

test-vm-ubuntu:
	bash libvirt/scripts/vm_tests.sh --distro ubuntu

test-vm-fedora:
	bash libvirt/scripts/vm_tests.sh --distro fedora

test-vm-destroy:
	bash libvirt/scripts/vm_tests.sh --destroy-all
