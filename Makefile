.PHONY: test test-vm test-vm-ubuntu test-vm-fedora test-vm-destroy

test:
	.venv/bin/python -m pytest

test-vm: test-vm-ubuntu test-vm-fedora

test-vm-ubuntu:
	bash libvirt/scripts/vm_tests.sh --distro ubuntu --recreate

test-vm-fedora:
	bash libvirt/scripts/vm_tests.sh --distro fedora --recreate

test-vm-destroy:
	bash libvirt/scripts/vm_tests.sh --destroy-all
