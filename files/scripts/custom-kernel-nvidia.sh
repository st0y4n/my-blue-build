#!/usr/bin/env bash
set -oue pipefail

echo "=== STARTING CACHYOS + NVIDIA + SECURE BOOT SETUP ==="

##################################
# 1. CACHY KERNEL SETUP
##################################
KERNEL_TYPE="${1:-cachyos-lto}"

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
# 2. NVIDIA DRIVER BUILD
##################################
if [[ "$IMAGE_NAME" == *open* ]]; then
    nvidia_repo='fedora-nvidia'
else
    nvidia_repo='fedora-nvidia-580'
fi

curl -fLsS --retry 5 -o "/etc/yum.repos.d/${nvidia_repo}.repo" "https://negativo17.org/repos/${nvidia_repo}.repo"

dnf install -y --setopt=install_weak_deps=False akmods gcc-c++

cp /usr/sbin/akmodsbuild /usr/sbin/akmodsbuild.backup
sed -i '/if \[\[ -w \/var \]\] ; then/,/fi/d' /usr/sbin/akmodsbuild

dnf install -y --setopt=install_weak_deps=False --enable-repo="${nvidia_repo}" nvidia-kmod-common nvidia-modprobe

echo "Compiling Nvidia kmod against CachyOS..."
akmods --force --kernels "${KERNEL_VERSION}" --kmod "nvidia"
mv /usr/sbin/akmodsbuild.backup /usr/sbin/akmodsbuild

modinfo /usr/lib/modules/${KERNEL_VERSION}/extra/nvidia/nvidia{,-drm,-modeset,-peermem,-uvm}.ko.xz > /dev/null || \
    (cat "/var/cache/akmods/nvidia/*.failed.log" && exit 1)

##################################
# 3. SECURE BOOT SIGNING
##################################
echo "Signing Kernel and Nvidia Modules..."

PUBLIC_KEY_CRT_PATH="/tmp/certs/public_key.crt"
PRIVATE_KEY_PATH="/tmp/certs/private_key.priv"
SIGNING_KEY="/tmp/certs/signing_key.pem"

# Sign the main kernel
openssl x509 -in "$PUBLIC_KEY_DER_PATH" -out "$PUBLIC_KEY_CRT_PATH"
sbsign --cert "$PUBLIC_KEY_CRT_PATH" --key "$PRIVATE_KEY_PATH" "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz" --output "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"

# Prep key for modules
cat "$PRIVATE_KEY_PATH" <(echo) "$PUBLIC_KEY_CRT_PATH" >> "$SIGNING_KEY"

# Sign Nvidia modules using the CachyOS build path
for module in /usr/lib/modules/"${KERNEL_VERSION}"/extra/nvidia/*.ko*; do
  module_basename="${module:0:-3}"
  module_suffix="${module: -3}"
  if [[ "$module_suffix" == ".xz" ]]; then
    xz --decompress "$module"
    openssl cms -sign -signer "${SIGNING_KEY}" -binary -in "$module_basename" -outform DER -out "${module_basename}.cms" -nocerts -noattr -nosmimecap
    /usr/lib/modules/"${KERNEL_VERSION}"/build/scripts/sign-file -s "${module_basename}.cms" sha256 "${PUBLIC_KEY_CRT_PATH}" "${module_basename}"
    xz -C crc32 -f "${module_basename}"
  else
    openssl cms -sign -signer "${SIGNING_KEY}" -binary -in "$module" -outform DER -out "${module}.cms" -nocerts -noattr -nosmimecap
    /usr/lib/modules/"${KERNEL_VERSION}"/build/scripts/sign-file -s "${module}.cms" sha256 "${PUBLIC_KEY_CRT_PATH}" "${module}"
  fi
done

##################################
# 4. NVIDIA USERSPACE & EXTRA TOOLS
##################################
nvidia_packages_list=(\
    'nvidia-driver' \
    'nvidia-driver-libs.i686' \
    'nvidia-persistenced' \
    'nvidia-settings' \
    'nvidia-driver-cuda' \
    'nvidia-driver-cuda-libs.i686' \
    'nvidia-container-toolkit' \
    'libnvidia-ml.i686' \
    'libnvidia-fbc' \
    'libnvidia-fbc.i686' \
    'libnvidia-gpucomp.i686' \
    'libva-nvidia-driver' \
)

curl -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo -o /etc/yum.repos.d/nvidia-container-toolkit.repo
sed -i 's/^gpgcheck=0/gpgcheck=1/' /etc/yum.repos.d/nvidia-container-toolkit.repo

if ! [ -f /etc/pki/tls/certs/ca-bundle.crt ]; then
    ln /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /etc/pki/tls/certs/ca-bundle.crt
fi

dnf -y \
    --setopt=install_weak_deps=False \
    --setopt=exclude= \
    install \
    --enablerepo='nvidia-container-toolkit' \
    --enablerepo="${nvidia_repo}" \
    "${nvidia_packages_list[@]}"

curl -L https://raw.githubusercontent.com/NVIDIA/dgx-selinux/master/bin/RHEL9/nvidia-container.pp -o nvidia-container.pp
semodule -i nvidia-container.pp

##################################
# 5. CLEANUP & RESTORE
##################################
echo "Cleaning up..."
dnf -y remove akmod-nvidia akmods kernel-headers *-devel-matched gcc-c++ || true

# Restore hooks
for _f in /usr/lib/kernel/install.d/05-rpmostree.install /usr/lib/kernel/install.d/50-dracut.install; do
    if [ -f "${_f}.bak" ]; then
        mv -f "${_f}.bak" "${_f}"
    fi
done

rm -f nvidia-container.pp
rm -f /etc/yum.repos.d/nvidia-container-toolkit.repo
rm -f "/etc/yum.repos.d/${nvidia_repo}.repo"
rm -f /etc/yum.repos.d/*copr*

echo "=== BUILD COMPLETE ==="