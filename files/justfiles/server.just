server-setup:
    #!/usr/bin/bash
    sudo loginctl enable-linger $USER
    systemctl --user enable --now podman-restart.service
    systemctl --user enable --now podman.socket
    sudo systemctl enable --now podman-auto-update.timer
    systemctl --user enable --now podman-auto-update.timer
    sudo mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.timer.d/
    sudo tee /etc/systemd/system/bootc-fetch-apply-updates.timer.d/override.conf > /dev/null << 'EOF'
    [Timer]
    OnBootSec=
    OnUnitInactiveSec=
    OnCalendar=
    OnCalendar=Sun *-*-* 04:00:00
    Persistent=true
    EOF
    sudo systemctl daemon-reload
    sudo systemctl restart bootc-fetch-apply-updates.timer
    sudo systemctl enable --now bootc-fetch-apply-updates.timer
    echo "net.ipv4.ip_unprivileged_port_start=69" | sudo tee /etc/sysctl.d/90-unprivileged-ports.conf
    sudo sysctl --system

server-remove:
    #!/usr/bin/bash
    sudo loginctl disable-linger $USER
    systemctl --user disable --now podman-restart.service
    systemctl --user disable --now podman.socket
    sudo systemctl disable --now podman-auto-update.timer
    systemctl --user disable --now podman-auto-update.timer
    sudo rm /etc/sysctl.d/90-unprivileged-ports.conf
    sudo sysctl --system

luks-bypass:
    #!/usr/bin/bash
    set -euo pipefail
    echo "Discovering system partition details..."
    # 1. Discover the true LUKS UUID from the hardware (bypassing crypttab entirely)
    LUKS_UUID=$(sudo blkid --match-token TYPE=crypto_LUKS -s UUID -o value | head -n 1)
    if [ -z "${LUKS_UUID}" ]; then
        echo "Error: Could not find an active LUKS partition on this system" >&2
        exit 1
    fi
    echo " -> Found backing LUKS volume UUID: ${LUKS_UUID}"
    # 2. Extract the unencrypted /boot partition's UUID cleanly
    BOOT_UUID=$(findmnt -n -o UUID /boot)
    echo " -> Found /boot partition UUID: ${BOOT_UUID}"
    # 3. Securely generate the 512-byte keyfile
    echo "Generating secure 512-byte keyfile..."
    sudo dd if=/dev/urandom of=/boot/luks.key bs=512 count=1 status=none
    sudo chmod 0400 /boot/luks.key
    # 4. Enroll the generated keyfile
    echo "Enrolling the new keyfile into LUKS (You may be prompted for your current LUKS password)..."
    sudo cryptsetup luksAddKey "/dev/disk/by-uuid/${LUKS_UUID}" /boot/luks.key
    # 5 & 6. Combined Safety and Injection Phase (Truly Idempotent)
    echo "Atomically updating rpm-ostree kernel arguments..."
    # Hunt down any existing LUKS key arguments so we can delete them precisely
    # (The || true prevents the script from crashing if it doesn't find any old keys)
    OLD_KEY=$(rpm-ostree kargs | tr ' ' '\n' | grep '^rd.luks.key=' || true)
    OLD_OPT=$(rpm-ostree kargs | tr ' ' '\n' | grep '^rd.luks.options=.*keyfile-timeout' || true)
    # Safely build the command using a Bash Array
    KARGS_CMD=(sudo rpm-ostree kargs)
    if [ -n "$OLD_KEY" ]; then
        KARGS_CMD+=(--delete-if-present="$OLD_KEY")
    fi
    if [ -n "$OLD_OPT" ]; then
        KARGS_CMD+=(--delete-if-present="$OLD_OPT")
    fi
    # Append the fresh parameters
    KARGS_CMD+=(--append="rd.luks.key=${LUKS_UUID}=/luks.key:UUID=${BOOT_UUID}")
    KARGS_CMD+=(--append="rd.luks.options=${LUKS_UUID}=keyfile-timeout=10s")
    # Execute the dynamically built command
    "${KARGS_CMD[@]}"
    echo "Done! Please verify with 'rpm-ostree kargs' then reboot to test your hands-free boot."

luks-restore:
    #!/usr/bin/bash
    set -euo pipefail
    echo "Starting LUKS auto-unlock removal process..."
    # 1. Discover the true LUKS UUID from the hardware
    LUKS_UUID=$(sudo blkid --match-token TYPE=crypto_LUKS -s UUID -o value | head -n 1)
    if [ -z "${LUKS_UUID}" ]; then
        echo "Error: Could not find an active LUKS partition on this system." >&2
        exit 1
    fi
    echo " -> Found backing LUKS volume UUID: ${LUKS_UUID}"
    # 2. Atomically strip the kernel arguments
    echo "Removing LUKS auto-unlock kernel arguments..."
    OLD_KEY=$(rpm-ostree kargs | tr ' ' '\n' | grep '^rd.luks.key=' || true)
    OLD_OPT=$(rpm-ostree kargs | tr ' ' '\n' | grep '^rd.luks.options=.*keyfile-timeout' || true)
    KARGS_CMD=(sudo rpm-ostree kargs)
    if [ -n "$OLD_KEY" ]; then
        KARGS_CMD+=(--delete-if-present="$OLD_KEY")
    fi
    if [ -n "$OLD_OPT" ]; then
        KARGS_CMD+=(--delete-if-present="$OLD_OPT")
    fi
    # Only run the rpm-ostree command if there are actually keys to delete
    if [ ${#KARGS_CMD[@]} -gt 2 ]; then
        "${KARGS_CMD[@]}"
        echo " -> Kernel arguments successfully queued for removal."
    else
        echo " -> No auto-unlock kernel arguments found. Skipping."
    fi
    # 3. Unbind the keyfile from the LUKS drive and destroy it
    if [ -f /boot/luks.key ]; then
        echo "Unbinding the keyfile from the LUKS partition slots..."
        # luksRemoveKey safely finds the specific slot matching THIS file and wipes it.
        # It will leave your normal typed passphrase completely untouched.
        sudo cryptsetup luksRemoveKey "/dev/disk/by-uuid/${LUKS_UUID}" /boot/luks.key

        echo "Securely destroying the physical keyfile..."
        # Using 'shred' instead of 'rm' overwrites the data with zeros before deleting it,
        # ensuring no one can recover the file from your unencrypted /boot drive.
        sudo shred -u /boot/luks.key
        echo " -> Keyfile destroyed."
    else
        echo " -> Keyfile /boot/luks.key not found. Skipping LUKS slot removal."
    fi
    echo "Reversal complete! Please reboot. The system will halt at the password screen."

configure-cdrom-on:
    #!/usr/bin/bash
    # Prevent script from running as root directly; sudo inside handles the escalation safely
    if [ "$EUID" -eq 0 ]; then
        echo "Please run this script as a normal user (without sudo). It will prompt for privileges."
        exit 1
    fi
    echo "Unlocking CD-ROM door at the kernel level..."
    echo "dev.cdrom.lock=0" | sudo tee /etc/sysctl.d/99-cdrom.conf > /dev/null
    sudo sysctl --system
    echo "Creating udev hardware rules using native systemd-mount..."
    sudo tee /etc/udev/rules.d/99-cdrom.rules > /dev/null << 'EOF'
    # Use systemd-mount to safely create a transient mount unit on insertion
    ACTION=="change", SUBSYSTEM=="block", KERNEL=="sr0", ENV{ID_CDROM_MEDIA}=="1", RUN+="/usr/bin/systemd-mount --collect --no-block --options=ro /dev/sr0 /var/mnt/cdrom"
    # Use systemd-mount to cleanly destroy the transient mount unit on ejection
    ACTION=="change", SUBSYSTEM=="block", KERNEL=="sr0", ENV{ID_CDROM_MEDIA}!="1", RUN+="/usr/bin/systemd-mount --umount /var/mnt/cdrom"
    EOF
    echo "Reloading and triggering udev..."
    sudo udevadm control --reload-rules && sudo udevadm trigger
    echo "Done! CD-ROM Event-Driven Mounting is now CONFIGURED and ACTIVE."

configure-cdrom-off:
    #!/usr/bin/bash
    # Prevent script from running as root directly; sudo inside handles the escalation safely
    if [ "$EUID" -eq 0 ]; then
        echo "Please run this script as a normal user (without sudo). It will prompt for privileges."
        exit 1
    fi
    echo "Restoring default kernel CD-ROM lock..."
    sudo rm -f /etc/sysctl.d/99-cdrom.conf
    # Explicitly force the lock back on in active memory
    sudo sysctl -w dev.cdrom.lock=1
    echo "Safely unmounting the drive..."
    # Attempt to gracefully stop the transient systemd unit if it is currently running
    sudo systemd-mount --umount /var/mnt/cdrom 2>/dev/null || true
    # Fallback lazy unmount just to guarantee the directory is completely free
    sudo umount -l /var/mnt/cdrom 2>/dev/null || true
    echo "Removing udev hardware rules..."
    sudo rm -f /etc/udev/rules.d/99-cdrom.rules
    echo "Reloading and triggering udev to apply clean state..."
    sudo udevadm control --reload-rules && sudo udevadm trigger
    echo "Done! CD-ROM Event-Driven Mounting has been REMOVED."
