.PHONY: test test-vm test-vm-ubuntu test-vm-fedora test-vm-destroy
.PHONY: deploy teardown check generate generate-images build-images create-test-vms
.PHONY: build-lab-controller-vm build-lab-boot-node-vm

METHOD ?= compose
COUNT ?= 1
NIX ?= env NIX_CONFIG='experimental-features = nix-command flakes' nix
NIX_FLAKE_REF ?= path:.

test:
	$(NIX) develop $(NIX_FLAKE_REF) -c python -m pytest

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
	$(NIX) build $(NIX_FLAKE_REF)#docker-compose-yml --no-link --print-out-paths
	@echo "Building quadlet units..."
	$(NIX) build $(NIX_FLAKE_REF)#quadlet-units --no-link --print-out-paths
	@echo "Building helm values..."
	$(NIX) build $(NIX_FLAKE_REF)#helm-values --no-link --print-out-paths

generate-images:
	$(NIX) build $(NIX_FLAKE_REF)#boot-artifacts --no-link --print-out-paths

build-images:
	scripts/ops/build-images.sh

create-test-vms:
	scripts/ops/create-test-vms.sh --method $(METHOD) --count $(COUNT)

build-lab-controller-vm:
	$(NIX) build $(NIX_FLAKE_REF)#lab-controller-vm

build-lab-boot-node-vm:
	$(NIX) build $(NIX_FLAKE_REF)#lab-boot-node-vm
