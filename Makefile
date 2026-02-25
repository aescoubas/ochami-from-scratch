.PHONY: test test-vm test-vm-ubuntu test-vm-fedora test-vm-destroy

test:
	bash scripts/tests/test_common_args.sh
	bash scripts/tests/test_build_microservices.sh
	bash scripts/tests/test_magellan_discovery.sh
	bash scripts/tests/test_reverse_proxy_routing.sh
	bash scripts/tests/test_image_base_standardization.sh
	bash scripts/tests/test_build_artifact_extraction.sh
	bash scripts/tests/test_emulator_mount_behavior.sh
	bash scripts/tests/test_registration_contract_consistency.sh
	bash scripts/tests/test_deploy_policies_and_dedup.sh

test-vm: test-vm-ubuntu test-vm-fedora

test-vm-ubuntu:
	cd vagrant && vagrant up ubuntu --provision
	cd vagrant && vagrant ssh ubuntu -- sudo /home/vagrant/ochami-from-scratch/vagrant/scripts/run_tests.sh

test-vm-fedora:
	cd vagrant && vagrant up fedora --provision
	cd vagrant && vagrant ssh fedora -- sudo /home/vagrant/ochami-from-scratch/vagrant/scripts/run_tests.sh

test-vm-destroy:
	cd vagrant && vagrant destroy -f
