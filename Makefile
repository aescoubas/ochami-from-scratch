.PHONY: test deploy teardown check build-images build-boot-artifacts create-test-vms
.PHONY: health-check register-nodes register-bss-defaults push-boot-artifacts
.PHONY: lab lab-server lab-clients lab-destroy lab-status
.PHONY: rpm rpm-clean build-cli

# --- Configuration ---

METHOD ?= compose
PROFILE ?= official
COUNT ?= 1
TEST_NODE_IMAGE ?= almalinux

# Local source overrides for image builds
SMD_SRC ?=
BSS_SRC ?=
PCS_SRC ?=
CLOUD_INIT_SRC ?=
KEA_SYNC_SRC ?=
IMAGE_SOURCE_OVERRIDES = SMD_SRC="$(SMD_SRC)" BSS_SRC="$(BSS_SRC)" PCS_SRC="$(PCS_SRC)" CLOUD_INIT_SRC="$(CLOUD_INIT_SRC)" KEA_SYNC_SRC="$(KEA_SYNC_SRC)"

# --- Deployment targets ---

# Deploy the stack using the selected method and profile
deploy:
	$(IMAGE_SOURCE_OVERRIDES) OPENCHAMI_PROFILE=$(PROFILE) scripts/ops/deploy.sh --method $(METHOD)

# Tear down the running stack
teardown:
	scripts/ops/teardown.sh --method $(METHOD)

# Verify host dependencies for the selected deployment method
check:
	scripts/ops/check-deps.sh --method $(METHOD)

# --- Build targets ---

# Build OCI images, optionally from local source checkouts
build-images:
	$(IMAGE_SOURCE_OVERRIDES) OPENCHAMI_PROFILE=$(PROFILE) scripts/ops/build-images.sh

# Build PXE/iPXE boot artifacts
build-boot-artifacts:
	scripts/ops/build-boot-artifacts.sh

# --- Test VM targets ---

# Create libvirt test VMs for PXE booting (compose method)
create-test-vms:
	scripts/ops/create-test-vms.sh --method $(METHOD) --count $(COUNT)

# Run the unit/integration test suite
test:
	python3 -m pytest tests/

# --- Virtual test lab ---
# AlmaLinux server VM with RPM + quadlets, OpenSUSE PXE boot clients

# End-to-end: server + clients
lab: lab-server lab-clients

# Create and provision the AlmaLinux server VM
lab-server:
	$(IMAGE_SOURCE_OVERRIDES) OPENCHAMI_PROFILE=$(PROFILE) scripts/ops/lab.sh server

# Create PXE boot client VMs
lab-clients:
	LAB_CLIENT_COUNT=$(COUNT) scripts/ops/lab.sh clients --count $(COUNT)

# Tear down the entire lab
lab-destroy:
	scripts/ops/lab.sh destroy

# Show lab VM states and service health
lab-status:
	scripts/ops/lab.sh status

# --- Operational targets ---

# Run health checks against deployed services
health-check:
	scripts/ops/health-check.sh

# Register a node with SMD
# Usage: make register-nodes XNAME=x1000c0s0b0n0 MAC=02:00:00:00:00:01 IP=192.168.100.101 [BMC_IP=10.0.0.101]
XNAME ?=
MAC ?=
IP ?=
BMC_IP ?=
register-nodes:
	scripts/ops/register-nodes.sh --xname $(XNAME) --mac $(MAC) --ip $(IP) $(if $(BMC_IP),--bmc-ip $(BMC_IP))

# Register BSS boot defaults (or per-MAC with MAC= )
register-bss-defaults:
	scripts/ops/register-bss-defaults.sh $(if $(MAC),--mac $(MAC))

# Push pre-built boot artifacts to a remote OpenCHAMI server
# Usage: make push-boot-artifacts HOST=server ARTIFACTS_DIR=/path/to/artifacts [IMAGE_NAME=opensuse]
ARTIFACTS_DIR ?=
IMAGE_NAME ?=
push-boot-artifacts:
	scripts/ops/push-boot-artifacts.sh --host $(HOST) --artifacts-dir $(ARTIFACTS_DIR) $(if $(IMAGE_NAME),--image-name $(IMAGE_NAME))

# --- RPM packaging ---

RPM_VERSION ?= 0.1.0
RPM_RELEASE ?= 1
RPM_ARCH := $(shell uname -m)

# Path to the ochami-cli source — cloned locally on first use.
# Override OCHAMI_CLI_SRC to point at your own checkout if desired.
OCHAMI_CLI_REPO ?= https://github.com/OpenCHAMI/ochami.git
OCHAMI_CLI_SRC ?= $(CURDIR)/.ochami-cli

# Build the RPM package
rpm: openchami-$(RPM_VERSION)-$(RPM_RELEASE).$(RPM_ARCH).rpm

$(HOME)/rpmbuild:
	mkdir -p $(HOME)/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

$(HOME)/rpmbuild/SPECS/openchami.spec: ochami-from-scratch.spec $(HOME)/rpmbuild
	mkdir -p $(HOME)/rpmbuild/SPECS
	cp $< $@

# Clone ochami-cli for standalone checkouts (no-op when using superproject)
$(CURDIR)/.ochami-cli:
	git clone $(OCHAMI_CLI_REPO) $@

# Build the ochami CLI binary and completions
.PHONY: build-cli
build-cli: | $(OCHAMI_CLI_SRC)
	$(MAKE) -C $(OCHAMI_CLI_SRC) clean 2>/dev/null || true
	$(MAKE) -C $(OCHAMI_CLI_SRC)
	$(MAKE) -C $(OCHAMI_CLI_SRC) completions

RPM_SOURCES = ochami-from-scratch.spec $(wildcard deploy/quadlets/**/*) $(wildcard scripts/ops/*) $(wildcard scripts/ops/lib/*)

$(HOME)/rpmbuild/SOURCES/openchami-$(RPM_VERSION).tar.gz: $(HOME)/rpmbuild $(RPM_SOURCES) build-cli
	mkdir -p $(HOME)/rpmbuild/SOURCES
	rm -rf .rpm-staging
	mkdir -p .rpm-staging/ochami-cli/completions
	cp $(OCHAMI_CLI_SRC)/ochami .rpm-staging/ochami-cli/ochami
	cp $(OCHAMI_CLI_SRC)/completions/ochami.bash .rpm-staging/ochami-cli/completions/
	cp $(OCHAMI_CLI_SRC)/completions/ochami.fish .rpm-staging/ochami-cli/completions/
	cp $(OCHAMI_CLI_SRC)/completions/ochami.zsh  .rpm-staging/ochami-cli/completions/
	rm -f $(HOME)/rpmbuild/SOURCES/openchami-$(RPM_VERSION).tar.gz
	tar czvf $@ --transform 's,^,openchami-$(RPM_VERSION)/,' \
		ochami-from-scratch.spec \
		deploy/quadlets/ \
		scripts/ops/ \
		-C .rpm-staging ochami-cli/
	rm -rf .rpm-staging

$(HOME)/rpmbuild/RPMS/$(RPM_ARCH)/openchami-$(RPM_VERSION)-$(RPM_RELEASE).$(RPM_ARCH).rpm: $(HOME)/rpmbuild/SPECS/openchami.spec $(HOME)/rpmbuild/SOURCES/openchami-$(RPM_VERSION).tar.gz
	rpmbuild -ba $(HOME)/rpmbuild/SPECS/openchami.spec --define 'version $(RPM_VERSION)' --define 'rel $(RPM_RELEASE)'

openchami-$(RPM_VERSION)-$(RPM_RELEASE).$(RPM_ARCH).rpm: $(HOME)/rpmbuild/RPMS/$(RPM_ARCH)/openchami-$(RPM_VERSION)-$(RPM_RELEASE).$(RPM_ARCH).rpm
	cp $< $@

# Clean RPM build artifacts
rpm-clean:
	rm -rf $(HOME)/rpmbuild .rpm-staging
	rm -f openchami-*.rpm
