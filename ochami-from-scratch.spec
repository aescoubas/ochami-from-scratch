Name:           openchami
Version:        %{version}
Release:        %{rel}
Summary:        OpenCHAMI from-scratch deployment RPM package

License:        MIT
URL:            https://github.com/aescoubas/ochami-from-scratch
Source0:        %{name}-%{version}.tar.gz

Requires:       podman
Requires:       jq
Requires:       curl
Requires(post): coreutils
Requires(post): openssl
Requires(post): hostname
Requires(post): sed

%description
The quadlets, systemd units, config files, and operational scripts for the
ochami-from-scratch OpenCHAMI deployment.

%prep
%setup -q

%build
# CLI binary is pre-built and included in the source tarball

%install
# 1) Install config, unit, and script files
mkdir -p %{buildroot}/etc/openchami/configs \
         %{buildroot}/etc/openchami/pg-init \
         %{buildroot}/etc/containers/systemd \
         %{buildroot}/etc/systemd/system \
         %{buildroot}/usr/local/bin \
         %{buildroot}/usr/share/bash-completion/completions \
         %{buildroot}/usr/share/fish/vendor_completions.d \
         %{buildroot}/usr/share/zsh/site-functions \
         %{buildroot}/usr/libexec/openchami \
         %{buildroot}/usr/libexec/openchami/lib

cp -r deploy/quadlets/configs/*        %{buildroot}/etc/openchami/configs/
cp -r deploy/quadlets/containers/*     %{buildroot}/etc/containers/systemd/
cp    deploy/quadlets/pg-init/*        %{buildroot}/etc/openchami/pg-init/
cp    deploy/quadlets/.env.template    %{buildroot}/etc/openchami/configs/.env.template

# Move the target file from containers/ into the systemd system directory
mv %{buildroot}/etc/containers/systemd/openchami.target %{buildroot}/etc/systemd/system/openchami.target

# Install operational scripts
cp scripts/ops/deploy.sh               %{buildroot}/usr/libexec/openchami/
cp scripts/ops/teardown.sh             %{buildroot}/usr/libexec/openchami/
cp scripts/ops/health-check.sh         %{buildroot}/usr/libexec/openchami/
cp scripts/ops/check-deps.sh           %{buildroot}/usr/libexec/openchami/
cp scripts/ops/register-nodes.sh       %{buildroot}/usr/libexec/openchami/
cp scripts/ops/register-bss-defaults.sh %{buildroot}/usr/libexec/openchami/
cp scripts/ops/bootstrap.sh            %{buildroot}/usr/libexec/openchami/
cp scripts/ops/load-images.sh          %{buildroot}/usr/libexec/openchami/
cp scripts/ops/lib/common.sh           %{buildroot}/usr/libexec/openchami/lib/

# Install ochami CLI binary and shell completions
install -m755 ochami-cli/ochami   %{buildroot}/usr/local/bin/ochami
install -m644 ochami-cli/completions/ochami.bash %{buildroot}/usr/share/bash-completion/completions/ochami
install -m644 ochami-cli/completions/ochami.fish %{buildroot}/usr/share/fish/vendor_completions.d/ochami.fish
install -m644 ochami-cli/completions/ochami.zsh  %{buildroot}/usr/share/zsh/site-functions/_ochami

chmod +x %{buildroot}/usr/libexec/openchami/*.sh
chmod +x %{buildroot}/etc/openchami/pg-init/*.sh

%files
%config(noreplace) /etc/openchami/configs/*
%config(noreplace) /etc/openchami/configs/.env.template
/etc/containers/systemd/*
/etc/systemd/system/openchami.target
/etc/openchami/pg-init/multi-psql-db.sh
/usr/libexec/openchami/deploy.sh
/usr/libexec/openchami/teardown.sh
/usr/libexec/openchami/health-check.sh
/usr/libexec/openchami/check-deps.sh
/usr/libexec/openchami/register-nodes.sh
/usr/libexec/openchami/register-bss-defaults.sh
/usr/libexec/openchami/bootstrap.sh
/usr/libexec/openchami/load-images.sh
/usr/libexec/openchami/lib/common.sh
/usr/local/bin/ochami
/usr/share/bash-completion/completions/ochami
/usr/share/fish/vendor_completions.d/ochami.fish
/usr/share/zsh/site-functions/_ochami

%post
# bootstrap: generate secrets, create dirs, reload systemd
/usr/libexec/openchami/bootstrap.sh

%postun
# reload systemd on uninstall
systemctl daemon-reload
