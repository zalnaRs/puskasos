#!/usr/bin/env bash

set -euo pipefail

IMAGE_TAG="latest"
IMAGE_VARIANT_ID="$(grep '^VARIANT_ID=' /usr/lib/os-release | cut -d= -f2 | tr -d '"')"
IMAGE_REF="ghcr.io/zalnars/puskasos:${IMAGE_VARIANT_ID}"

sed -i '/^install squashfs /d' /usr/lib/modprobe.d/*.conf /etc/modprobe.d/*.conf 2>/dev/null || true

# https://github.com/ublue-os/bazzite/issues/4126#issuecomment-3980175243
dnf remove -y google-noto-fonts-all homebrew bazaar || true
# dnf install -y puskasos-logos
dnf reinstall -y polkit
dnf install -y anaconda-live firefox libblockdev-btrfs libblockdev-lvm libblockdev-dm

systemctl disable --global puskasos-flatpak-setup.service puskasos-flatpak-setup.timer podman-auto-update.timer flatpak-user-update.timer || true
systemctl disable rpm-ostreed-automatic.timer rpm-ostree-countme.service rpm-ostree-countme.timer bootloader-update.service || true

rm -f /usr/share/applications/org.mozilla.Firefox.desktop /usr/share/applications/org.mozilla.firefox.desktop /usr/share/applications/firefox.desktop /usr/share/applications/firefox-wayland.desktop /usr/share/applications/firefox-x11.desktop

# add installer to kickoff
sed -i '/^Prepend=/s/$/;liveinst.desktop/' /usr/share/kde-settings/kde-profile/default/xdg/kicker-extra-favoritesrc || true

# Require the embedded installer image in containers-storage to satisfy the
# same sigstore policy used for registry pulls.
if command -v jq >/dev/null 2>&1 && [[ -f /etc/containers/policy.json ]]; then
  jq --arg image_ref "ghcr.io/zalnars/puskasos" \
      '.transports["containers-storage"][""] =
      [
          {
              "type": "sigstoreSigned",
              "keyPaths": [
                  "/usr/share/pki/containers/puskasos.pub",
                  "/usr/share/pki/containers/puskasos-2025.pub"
              ],
              "signedIdentity": {
                  "type": "exactRepository",
                  "dockerRepository": $image_ref
              }
          }
      ]' /etc/containers/policy.json | tee /etc/containers/policy.json.tmp >/dev/null
  mv /etc/containers/policy.json.tmp /etc/containers/policy.json
fi

# Disable suspend/sleep during live environment and initial setup
# This prevents the system from suspending during installation or first-boot user creation
cat > /usr/share/glib-2.0/schemas/zz3-puskasos-installer-power.gschema.override <<'SCHEMA_EOF'
[org.gnome.settings-daemon.plugins.power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0

[org.gnome.desktop.session]
idle-delay=uint32 0
SCHEMA_EOF

sed -i '/^UMASK[[:blank:]]/s/027/022/' /etc/login.defs || true

# don't autostart gnome-software session service
rm -f /etc/xdg/autostart/org.gnome.Software.desktop

# disable the gnome-software shell search provider
cat > /usr/share/gnome-shell/search-providers/org.gnome.Software-search-provider.ini <<'EOF_GNOME_SOFTWARE'
DefaultDisabled=true
EOF_GNOME_SOFTWARE

sed -i -e 's/ Fedora/ puskasos/' /usr/share/anaconda/gnome/fedora-welcome || true
sed -i -e 's/Fedora/puskasos/g' /usr/share/anaconda/gnome/org.fedoraproject.welcome-screen.desktop || true

mkdir -p /etc/anaconda/profile.d
cat > /etc/anaconda/profile.d/puskasos.conf <<'EOF_PROFILE'
# Anaconda configuration file for puskasos

[Profile]
profile_id = puskasos

[Profile Detection]
os_id = puskasos

[Network]
default_on_boot = FIRST_WIRED_WITH_LINK

[Bootloader]
efi_dir = fedora
menu_auto_hide = True

[Storage]
default_scheme = BTRFS
btrfs_compression = zstd:1
default_partitioning =
    /     (min 1 GiB, max 70 GiB)
    /home (min 500 MiB, free 50 GiB)
    /var  (btrfs)

[User Interface]
custom_stylesheet = /usr/share/anaconda/pixmaps/silverblue/fedora-silverblue.css
hidden_spokes =
    NetworkSpoke
    PasswordSpoke
hidden_webui_pages =
    root-password
    network
password_policies =
        root (quality 100, length 15)
        user (quality 50, length 8)
        luks (quality 100, length 15)
EOF_PROFILE

# Fetch the Secureboot Public Key
sbkey='https://puskasos.014321.xyz/.well-known/public_key.der'
curl --retry 15 -fsSL -o /etc/sb_pubkey.der "${sbkey}" || true

# Enroll Secureboot Key
mkdir -p /usr/share/anaconda/post-scripts
cat > /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks <<'EOF_SB'
%post --erroronfail --nochroot
set -oue pipefail

readonly ENROLLMENT_PASSWORD="puskasos"
readonly SECUREBOOT_KEY="/etc/sb_pubkey.der"

if [[ ! -d "/sys/firmware/efi" ]]; then
    echo "EFI mode not detected. Skipping key enrollment."
    exit 0
fi

if [[ ! -f "$SECUREBOOT_KEY" ]]; then
    echo "Secure boot key not provided: $SECUREBOOT_KEY"
    exit 0
fi

if grep -Eq 'Jupiter|Galileo' /sys/devices/virtual/dmi/id/product_name; then
    echo "Steam Deck hardware detected. Skipping key enrollment."
    exit 0
fi

mokutil --timeout -1 || true
echo -e "$ENROLLMENT_PASSWORD\n$ENROLLMENT_PASSWORD" | mokutil --import "$SECUREBOOT_KEY" || true
%end
EOF_SB

# Interactive Kickstart
touch /usr/share/anaconda/interactive-defaults.ks
grep -q "^ostreecontainer --url=${IMAGE_REF}:${IMAGE_TAG} --transport=containers-storage$" /usr/share/anaconda/interactive-defaults.ks || cat >> /usr/share/anaconda/interactive-defaults.ks <<EOF_KS
ostreecontainer --url=${IMAGE_REF}:${IMAGE_TAG} --transport=containers-storage
%include /usr/share/anaconda/post-scripts/install-configure-upgrade.ks
%include /usr/share/anaconda/post-scripts/secureboot-enroll-key.ks
EOF_KS

# Signed Images
cat > /usr/share/anaconda/post-scripts/install-configure-upgrade.ks <<EOF_SWITCH
%post --erroronfail
bootc switch --mutate-in-place --transport registry ${IMAGE_REF}:${IMAGE_TAG}
%end
EOF_SWITCH

# enable xwayland
rm -f /etc/sway/config.d/99-noxwayland.conf /etc/systemd/user/org.gnome.Shell@user.service.d/override.conf /etc/systemd/user/plasma-kwin_wayland.service.d/override.conf

# hide root account creation in cockpit
cat >> /usr/share/cockpit/branding/fedora/branding.css <<'EOF_BRANDING_ROOT'
.anaconda {
    .pf-v6-c-form__section:has(#anaconda-screen-accounts-root-account-enable-root-account) {
        /* Hide the whole section with "Enable root account". Might be not as reliable as it seems to be */
        display: none;
    }
}
EOF_BRANDING_ROOT

# disable password strength labels
cat >> /usr/share/cockpit/branding/fedora/branding.css <<'EOF_BRANDING_PASSWORD'
.anaconda {
    #disk-encryption-password-strength-label {
        display: none;
    }

    #anaconda-screen-accounts-create-account-password-strength-label {
        display: none;
    }
}
EOF_BRANDING_PASSWORD

# Disable "ask an AI chatbot" in the context menu
mkdir -p /etc/firefox/policies
cat > /etc/firefox/policies/policies.json << 'EOF_FIREFOX'
{
  "policies": {
    "Preferences": {
      "browser.ml.chat.menu": { "Value": false, "Status": "locked" },
      "browser.ml.enable": { "Value": false, "Status": "locked" }
    }
  }
}
EOF_FIREFOX
