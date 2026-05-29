#!/usr/bin/env bash
set -oue pipefail

echo "=== STARTING CACHYOS + SECURE BOOT SETUP ==="

##################################
# 1. CACHY KERNEL SETUP
##################################
KERNEL_TYPE="${1:-cachyos}"

case "${KERNEL_TYPE}" in
cachyos-lto)
    COPR_REPO="bieszczaders/kernel-cachyos-lto"
    KERNEL_PACKAGES="kernel-cachyos-lto kernel-cachyos-lto-core kernel-cachyos-lto-modules kernel-cachyos-lto-devel-matched"
    ;;
cachyos-lts-lto)
    COPR_REPO="bieszczaders/kernel-cachyos-lto"
    KERNEL_PACKAGES="kernel-cachyos-lts-lto kernel-cachyos-lts-lto-core kernel-cachyos-lts-lto-modules kernel-cachyos-lts-lto-devel-matched"
    ;;
cachyos)
    COPR_REPO="bieszczaders/kernel-cachyos"
    KERNEL_PACKAGES="kernel-cachyos kernel-cachyos-core kernel-cachyos-modules kernel-cachyos-devel-matched"
    ;;
cachyos-rt)
    COPR_REPO="bieszczaders/kernel-cachyos"
    KERNEL_PACKAGES="kernel-cachyos-rt kernel-cachyos-rt-core kernel-cachyos-rt-modules kernel-cachyos-rt-devel-matched"
    ;;
cachyos-lts)
    COPR_REPO="bieszczaders/kernel-cachyos"
    KERNEL_PACKAGES="kernel-cachyos-lts kernel-cachyos-lts-core kernel-cachyos-lts-modules kernel-cachyos-lts-devel-matched"
    ;;
*)
    echo "Unsupported kernel type: ${KERNEL_TYPE}"
    exit 1
    ;;
esac

# Disable install hooks to prevent rpm-ostree bootloader panic
for _f in /usr/lib/kernel/install.d/05-rpmostree.install /usr/lib/kernel/install.d/50-dracut.install; do
    if [ -f "${_f}" ]; then
        mv "${_f}" "${_f}.bak"
        printf '#!/bin/sh\nexit 0\n' > "${_f}"
        chmod +x "${_f}"
    fi
done

echo "Removing stock kernel..."
dnf -y remove kernel kernel-core kernel-modules kernel-modules-extra kernel-devel || true
rm -rf /usr/lib/modules/* || true

echo "Enabling COPR and installing ${KERNEL_TYPE}..."
dnf -y copr enable "${COPR_REPO}"
dnf -y install ${KERNEL_PACKAGES}

# CRITICAL: Capture the new kernel version dynamically for the rest of the script!
KERNEL_VERSION="$(ls -1 /usr/lib/modules | head -n 1)"
echo "Active Kernel Version: ${KERNEL_VERSION}"


##################################
# 2. SECURE BOOT SIGNING
##################################
echo "Signing Kernel Modules..."

PUBLIC_KEY_CRT_PATH="/tmp/certs/public_key.crt"
PRIVATE_KEY_PATH="/tmp/certs/private_key.priv"
SIGNING_KEY="/tmp/certs/signing_key.pem"

# Sign the main kernel
openssl x509 -in "$PUBLIC_KEY_DER_PATH" -out "$PUBLIC_KEY_CRT_PATH"
sbsign --cert "$PUBLIC_KEY_CRT_PATH" --key "$PRIVATE_KEY_PATH" "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz" --output "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"

# Prep key for modules
cat "$PRIVATE_KEY_PATH" <(echo) "$PUBLIC_KEY_CRT_PATH" >> "$SIGNING_KEY"

##################################
# 3. CLEANUP & RESTORE
##################################

# Restore hooks
for _f in /usr/lib/kernel/install.d/05-rpmostree.install /usr/lib/kernel/install.d/50-dracut.install; do
    if [ -f "${_f}.bak" ]; then
        mv -f "${_f}.bak" "${_f}"
    fi
done

rm -f /etc/yum.repos.d/*copr*

echo "=== BUILD COMPLETE ==="