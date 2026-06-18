server-setup:
    #!/usr/bin/bash
    sudo loginctl enable-linger $USER
    systemctl --user enable --now podman-restart.service

server-remove:
    #!/usr/bin/bash
    sudo loginctl disable-linger $USER
    systemctl --user disable --now podman-restart.service
