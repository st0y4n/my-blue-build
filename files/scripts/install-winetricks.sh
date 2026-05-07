set -oue pipefail


curl -fL https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks \
    -o /usr/bin/winetricks
chmod +x /usr/bin/winetricks