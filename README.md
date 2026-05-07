## Installation

To rebase an existing atomic Fedora installation to the latest build:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  bootc switch ghcr.io/st0y4n/base-images/fedora-kinoite:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  bootc switch --enforce-container-sigpolicy ghcr.io/st0y4n/base-images/fedora-kinoite:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

## Verification

```bash
cosign verify --key cosign.pub ghcr.io/st0y4n/base-images/fedora-base:latest
```
