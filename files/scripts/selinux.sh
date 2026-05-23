#!/usr/bin/env bash
set -oue pipefail

echo "Baking custom SELinux policies..."

semodule -X 200 -i ./selinux/container200.pp
semodule -X 200 -i ./selinux/flatpak200.pp
semodule -X 200 -i ./selinux/waydroid200.pp

echo "SELinux policies baked successfully."