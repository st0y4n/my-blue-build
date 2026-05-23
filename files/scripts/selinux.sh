#!/usr/bin/env bash
set -oue pipefail

echo "Baking custom SELinux policies..."

semodule -X 200 -i ./selinux/container.cil
semodule -X 200 -i ./selinux/flatpak.cil
semodule -X 200 -i ./selinux/waydroid.cil

echo "SELinux policies baked successfully."