.PHONY: test deploy teardown check build-images build-boot-artifacts create-test-vms
.PHONY: health-check register-nodes register-bss-defaults
.PHONY: lab lab-server lab-clients lab-destroy lab-status
.PHONY: rpm rpm-clean

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

# Register nodes with SMD
register-nodes:
	scripts/ops/register-nodes.sh

# Register BSS boot defaults
register-bss-defaults:
	scripts/ops/register-bss-defaults.sh

# --- RPM packaging ---

GIT     ?= $(shell command -v git 2>/dev/null)
TAG     ?= $(shell $(GIT) describe --tags --always --abbrev=0)
RPM_VERSION ?= $(patsubst v%,%,$(TAG))
RPM_RELEASE ?= 1

# Build the RPM package
rpm: ochami-from-scratch-$(RPM_VERSION)-$(RPM_RELEASE).noarch.rpm

$(HOME)/rpmbuild:
	mkdir -p $(HOME)/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

$(HOME)/rpmbuild/SPECS/ochami-from-scratch.spec: ochami-from-scratch.spec $(HOME)/rpmbuild
	mkdir -p $(HOME)/rpmbuild/SPECS
	cp $< $@

RPM_SOURCES = ochami-from-scratch.spec $(wildcard deploy/quadlets/**/*) $(wildcard scripts/ops/*) $(wildcard scripts/ops/lib/*)

$(HOME)/rpmbuild/SOURCES/ochami-from-scratch-$(RPM_VERSION).tar.gz: $(HOME)/rpmbuild $(RPM_SOURCES)
	mkdir -p $(HOME)/rpmbuild/SOURCES
	rm -f $(HOME)/rpmbuild/SOURCES/ochami-from-scratch-$(RPM_VERSION).tar.gz
	tar czvf $@ --transform 's,^,ochami-from-scratch-$(RPM_VERSION)/,' \
		ochami-from-scratch.spec \
		deploy/quadlets/ \
		scripts/ops/

$(HOME)/rpmbuild/RPMS/noarch/ochami-from-scratch-$(RPM_VERSION)-$(RPM_RELEASE).noarch.rpm: $(HOME)/rpmbuild/SPECS/ochami-from-scratch.spec $(HOME)/rpmbuild/SOURCES/ochami-from-scratch-$(RPM_VERSION).tar.gz
	rpmbuild -ba $(HOME)/rpmbuild/SPECS/ochami-from-scratch.spec --define 'version $(RPM_VERSION)' --define 'rel $(RPM_RELEASE)'

ochami-from-scratch-$(RPM_VERSION)-$(RPM_RELEASE).noarch.rpm: $(HOME)/rpmbuild/RPMS/noarch/ochami-from-scratch-$(RPM_VERSION)-$(RPM_RELEASE).noarch.rpm
	cp $< $@

# Clean RPM build artifacts
rpm-clean:
	rm -rf $(HOME)/rpmbuild
	rm -f ochami-from-scratch-*.noarch.rpm
