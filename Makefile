.PHONY: test test-vm test-vm-ubuntu test-vm-fedora test-vm-destroy
.PHONY: deploy teardown check generate generate-images build-images create-test-vms
.PHONY: build-lab-controller-vm build-lab-boot-node-vm
.PHONY: rpm rpm-clean

METHOD ?= compose
COUNT ?= 1
PROFILE ?= official
TEST_NODE_IMAGE ?= nixos
SMD_SRC ?=
BSS_SRC ?=
PCS_SRC ?=
CLOUD_INIT_SRC ?=
KEA_SYNC_SRC ?=
PROFILE_SUFFIX = $(if $(filter official,$(PROFILE)),,-$(PROFILE))
IMAGE_SOURCE_OVERRIDES = SMD_SRC="$(SMD_SRC)" BSS_SRC="$(BSS_SRC)" PCS_SRC="$(PCS_SRC)" CLOUD_INIT_SRC="$(CLOUD_INIT_SRC)" KEA_SYNC_SRC="$(KEA_SYNC_SRC)"
NIX_BOOT_IMAGE_ENV = OPENCHAMI_TEST_NODE_IMAGE=$(TEST_NODE_IMAGE)
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
	$(IMAGE_SOURCE_OVERRIDES) OPENCHAMI_PROFILE=$(PROFILE) $(NIX_BOOT_IMAGE_ENV) scripts/ops/deploy.sh --method $(METHOD)

teardown:
	OPENCHAMI_PROFILE=$(PROFILE) scripts/ops/teardown.sh --method $(METHOD)

check:
	scripts/ops/check-deps.sh --method $(METHOD)

generate:
	@echo "Building docker-compose directory..."
	$(NIX_BOOT_IMAGE_ENV) $(NIX) build --impure $(NIX_FLAKE_REF)#docker-compose-yml$(PROFILE_SUFFIX) --no-link --print-out-paths
	@echo "Building quadlet units..."
	$(NIX_BOOT_IMAGE_ENV) $(NIX) build --impure $(NIX_FLAKE_REF)#quadlet-units$(PROFILE_SUFFIX) --no-link --print-out-paths
	@echo "Building helm values..."
	$(NIX_BOOT_IMAGE_ENV) $(NIX) build --impure $(NIX_FLAKE_REF)#helm-values$(PROFILE_SUFFIX) --no-link --print-out-paths

generate-static:
	@set -e; \
	echo "==> Generating static artifacts for profile=$(PROFILE)..."; \
	echo ""; \
	echo "    Building docker-compose, quadlets, and helm-values (single nix eval)..."; \
	OUTPUTS="$$($(NIX_BOOT_IMAGE_ENV) $(NIX) build --impure \
	  $(NIX_FLAKE_REF)#docker-compose-yml$(PROFILE_SUFFIX) \
	  $(NIX_FLAKE_REF)#quadlet-units$(PROFILE_SUFFIX) \
	  $(NIX_FLAKE_REF)#helm-values$(PROFILE_SUFFIX) \
	  --no-link --print-out-paths)"; \
	COMPOSE_OUT="$$(echo "$$OUTPUTS" | sed -n '1p')"; \
	QUADLET_OUT="$$(echo "$$OUTPUTS" | sed -n '2p')"; \
	HELM_OUT="$$(echo "$$OUTPUTS" | sed -n '3p')"; \
	echo ""; \
	echo "==> Copying docker-compose artifacts..."; \
	rm -rf ochami-docker-compose/docker-compose.yml ochami-docker-compose/configs ochami-docker-compose/pg-init ochami-docker-compose/.env.template; \
	cp "$$COMPOSE_OUT"/docker-compose.yml ochami-docker-compose/docker-compose.yml; \
	cp -r "$$COMPOSE_OUT"/configs ochami-docker-compose/configs; \
	cp -r "$$COMPOSE_OUT"/pg-init ochami-docker-compose/pg-init; \
	cp "$$COMPOSE_OUT"/.env.template ochami-docker-compose/.env.template; \
	chmod -R u+w ochami-docker-compose/; \
	echo "==> Copying quadlet artifacts..."; \
	rm -rf ochami-quadlets/containers ochami-quadlets/configs ochami-quadlets/pg-init ochami-quadlets/.env.template; \
	cp -r "$$QUADLET_OUT"/containers ochami-quadlets/containers; \
	cp -r "$$QUADLET_OUT"/configs ochami-quadlets/configs; \
	cp -r "$$QUADLET_OUT"/pg-init ochami-quadlets/pg-init; \
	cp "$$QUADLET_OUT"/.env.template ochami-quadlets/.env.template; \
	chmod -R u+w ochami-quadlets/; \
	echo "==> Copying helm values..."; \
	cp "$$HELM_OUT" ochami-helm/values.yaml; \
	chmod u+w ochami-helm/values.yaml; \
	echo ""; \
	echo "==> Static artifacts written to:"; \
	echo "    ochami-docker-compose/"; \
	echo "    ochami-quadlets/"; \
	echo "    ochami-helm/values.yaml"

generate-images:
	$(NIX_BOOT_IMAGE_ENV) $(NIX) build $(NIX_FLAKE_REF)#boot-artifacts-$(TEST_NODE_IMAGE) --no-link --print-out-paths

build-images:
	$(IMAGE_SOURCE_OVERRIDES) OPENCHAMI_PROFILE=$(PROFILE) $(NIX_BOOT_IMAGE_ENV) scripts/ops/build-images.sh

create-test-vms:
	$(NIX_BOOT_IMAGE_ENV) scripts/ops/create-test-vms.sh --method $(METHOD) --count $(COUNT)

build-lab-controller-vm:
	$(NIX_BOOT_IMAGE_ENV) $(NIX) build --impure $(NIX_FLAKE_REF)#lab-controller-vm

build-lab-boot-node-vm:
	$(NIX_BOOT_IMAGE_ENV) $(NIX) build --impure $(NIX_FLAKE_REF)#lab-boot-node-vm

# --- RPM packaging (mirrors openchami-release style) ---

GIT     ?= $(shell command -v git 2>/dev/null)
TAG     ?= $(shell $(GIT) describe --tags --always --abbrev=0)
RPM_VERSION ?= $(patsubst v%,%,$(TAG))
RPM_RELEASE ?= 1

rwildcard = $(foreach d,$(wildcard $(1:=/*)),$(call rwildcard,$d,$2) $(filter $(subst *,%,$2),$d))

rpm: ochami-from-scratch-$(RPM_VERSION)-$(RPM_RELEASE).noarch.rpm

$(HOME)/rpmbuild:
	mkdir -p $(HOME)/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

$(HOME)/rpmbuild/SPECS/ochami-from-scratch.spec: ochami-from-scratch.spec $(HOME)/rpmbuild
	mkdir -p $(HOME)/rpmbuild/SPECS
	cp $< $@

$(HOME)/rpmbuild/SOURCES/ochami-from-scratch-$(RPM_VERSION).tar.gz: $(HOME)/rpmbuild $(call rwildcard,.,*)
	mkdir -p $(HOME)/rpmbuild/SOURCES
	rm -f $(HOME)/rpmbuild/SOURCES/ochami-from-scratch-$(RPM_VERSION).tar.gz
	tar czvf $@ --transform 's,^,ochami-from-scratch-$(RPM_VERSION)/,' \
		ochami-from-scratch.spec \
		ochami-quadlets/ \
		scripts/ops/

$(HOME)/rpmbuild/RPMS/noarch/ochami-from-scratch-$(RPM_VERSION)-$(RPM_RELEASE).noarch.rpm: $(HOME)/rpmbuild/SPECS/ochami-from-scratch.spec $(HOME)/rpmbuild/SOURCES/ochami-from-scratch-$(RPM_VERSION).tar.gz
	rpmbuild -ba $(HOME)/rpmbuild/SPECS/ochami-from-scratch.spec --define 'version $(RPM_VERSION)' --define 'rel $(RPM_RELEASE)'

ochami-from-scratch-$(RPM_VERSION)-$(RPM_RELEASE).noarch.rpm: $(HOME)/rpmbuild/RPMS/noarch/ochami-from-scratch-$(RPM_VERSION)-$(RPM_RELEASE).noarch.rpm
	cp $< $@

rpm-clean:
	rm -rf $(HOME)/rpmbuild
	rm -f ochami-from-scratch-*.noarch.rpm
