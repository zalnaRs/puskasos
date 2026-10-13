#!/usr/bin/env bash

set -euo pipefail

IMAGE_REPO="ghcr.io/zalnars/puskasos"
IMAGE_TAG="$(grep '^VARIANT_ID=' /usr/lib/os-release | cut -d= -f2 | tr -d '"')"

if [[ -z "${IMAGE_TAG}" ]]; then
  IMAGE_TAG="latest"
fi

dnf install -y anaconda-live anaconda-install-env-deps anaconda-dracut dracut-config-generic dracut-network libblockdev-btrfs libblockdev-lvm libblockdev-dm

dnf clean all

mkdir -p /usr/share/anaconda/post-scripts
touch /usr/share/anaconda/interactive-defaults.ks

systemctl disable --global podman-auto-update.timer flatpak-user-update.timer || true
systemctl disable rpm-ostreed-automatic.timer rpm-ostree-countme.service rpm-ostree-countme.timer bootloader-update.service || true

sed -i '/^Prepend=/s/$/;liveinst.desktop/' /usr/share/kde-settings/kde-profile/default/xdg/kicker-extra-favoritesrc || true

if ! grep -q "^ostreecontainer --url=${IMAGE_REPO}:${IMAGE_TAG} --transport=containers-storage" /usr/share/anaconda/interactive-defaults.ks; then
  cat >> /usr/share/anaconda/interactive-defaults.ks <<ANACONDA_KS
ostreecontainer --url=${IMAGE_REPO}:${IMAGE_TAG} --transport=containers-storage
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
ANACONDA_KS
fi

cat > /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<INSTALL_SWITCH
%post --erroronfail
bootc switch --mutate-in-place --transport registry ${IMAGE_REPO}:${IMAGE_TAG}
%end
INSTALL_SWITCH
