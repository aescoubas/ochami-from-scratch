.PHONY: test test-vm test-vm-ubuntu test-vm-fedora test-vm-destroy
.PHONY: deploy teardown check generate generate-images build-images create-test-vms

METHOD ?= compose
COUNT ?= 1

test:
	nix develop -c python -m pytest

test-vm: test-vm-ubuntu test-vm-fedora

test-vm-ubuntu:
	bash libvirt/scripts/vm_tests.sh --distro ubuntu --recreate

test-vm-fedora:
	bash libvirt/scripts/vm_tests.sh --distro fedora --recreate

test-vm-destroy:
	bash libvirt/scripts/vm_tests.sh --destroy-all

deploy:
	scripts/ops/deploy.sh --method $(METHOD)

teardown:
	scripts/ops/teardown.sh --method $(METHOD)

check:
	scripts/ops/check-deps.sh --method $(METHOD)

generate:
	@echo "Building docker-compose.yml..."
	nix build .#docker-compose-yml --no-link --print-out-paths
	@echo "Building quadlet units..."
	nix build .#quadlet-units --no-link --print-out-paths
	@echo "Building helm values..."
	nix build .#helm-values --no-link --print-out-paths

generate-images:
	nix build .#boot-artifacts --no-link --print-out-paths

build-images:
	scripts/ops/build-images.sh

create-test-vms:
	scripts/ops/create-test-vms.sh --count $(COUNT)
