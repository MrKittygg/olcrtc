#!/usr/bin/env bash

set -eo pipefail

GO_VERSION="1.26.3"
GO_ARCHIVE="go${GO_VERSION}.linux-amd64.tar.gz"
GO_URL="https://go.dev/dl/${GO_ARCHIVE}"

if [[ $EUID -ne 0 ]]; then
    echo "Error: run the script as root."
    exit 1
fi

echo "======================================"
echo "Installing dependencies"
echo "======================================"

apt update
apt install -y git wget curl build-essential

echo
echo "======================================"
echo "Install Go ${GO_VERSION}"
echo "======================================"

cd /tmp
wget -O "${GO_ARCHIVE}" "${GO_URL}"

rm -rf /usr/local/go
tar -C /usr/local -xzf "${GO_ARCHIVE}"

export PATH=$PATH:/usr/local/go/bin

if ! grep -q "/usr/local/go/bin" /root/.bashrc; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /root/.bashrc
fi

if ! grep -q '$HOME/go/bin' /root/.bashrc; then
    echo 'export PATH="$HOME/go/bin:$PATH"' >> /root/.bashrc
fi

export PATH=$PATH:/root/go/bin

echo
echo "======================================"
echo "Install Mage"
echo "======================================"

go install github.com/magefile/mage@latest

echo
echo "======================================"
echo "Cloning a repository"
echo "======================================"

cd /root

if [[ ! -d olcrtc ]]; then
    git clone https://github.com/openlibrecommunity/olcrtc --recurse-submodules
fi

cd olcrtc

echo
echo "======================================"
echo "Creating swap (if missing)"
echo "======================================"

if ! swapon --show | grep -q "/swapfile"; then

    if [[ ! -f /swapfile ]]; then

        if ! fallocate -l 2G /swapfile; then
            dd if=/dev/zero of=/swapfile bs=1M count=2048
        fi

        chmod 600 /swapfile
        mkswap /swapfile
    fi

    swapon /swapfile

    if ! grep -q "^/swapfile" /etc/fstab; then
        echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
fi

echo
echo "======================================"
echo "Project build"
echo "======================================"

mage build

if [[ ! -f build/olcrtc-linux-amd64 ]]; then
    echo "Error: the build failed."
    exit 1
fi

########################################
# Provider selection
########################################

echo
echo "======================================"
echo "Select conferencing provider"
echo "======================================"
echo
echo "1) Jitsi"
echo "2) Telemost"
echo "3) Jitsi + Telemost"
echo

while true; do
    printf "Select an option [1-3]: " >/dev/tty
    IFS= read -r PROVIDER_CHOICE </dev/tty

    case "$PROVIDER_CHOICE" in
        1)
            INSTALL_JITSI=true
            INSTALL_TELEMOST=false
            break
            ;;
        2)
            INSTALL_JITSI=false
            INSTALL_TELEMOST=true
            break
            ;;
        3)
            INSTALL_JITSI=true
            INSTALL_TELEMOST=true
            break
            ;;
        *)
            echo "Invalid selection. Please enter 1, 2 or 3."
            ;;
    esac
done

########################################
# Jitsi configuration
########################################

mkdir -p /opt/olcrtc

if [[ "$INSTALL_JITSI" == true ]]; then

    echo
    echo "======================================"
    echo "Jitsi configuration"
    echo "======================================"

    JITSI_ROOM=""

    while [[ -z "$JITSI_ROOM" ]]; do
        printf "Enter Jitsi room URL: " >/dev/tty
        IFS= read -r JITSI_ROOM </dev/tty
    done

    JITSI_KEY=""

    while [[ -z "$JITSI_KEY" ]]; do
        printf "Enter Jitsi crypto key: " >/dev/tty
        IFS= read -rs JITSI_KEY </dev/tty
        echo >/dev/tty
    done

    cp docs/examples/server/server.jitsi.datachannel.yaml /opt/olcrtc/server.jitsi.yaml

    sed -i "s|ROOM_ID|$JITSI_ROOM|" /opt/olcrtc/server.jitsi.yaml
    sed -i "s|CRYPTO_KEY|$JITSI_KEY|" /opt/olcrtc/server.jitsi.yaml

fi


########################################
# Telemost configuration
########################################

if [[ "$INSTALL_TELEMOST" == true ]]; then

    echo
    echo "======================================"
    echo "Telemost configuration"
    echo "======================================"
    echo
    echo "Note:"
    echo "Telemost requires an existing meeting."
    echo "This installer does not create Telemost meetings."
    echo

    TELEMOST_ROOM=""

    while [[ -z "$TELEMOST_ROOM" ]]; do
        printf "Enter Telemost room URL: " >/dev/tty
        IFS= read -r TELEMOST_ROOM </dev/tty
    done

    TELEMOST_KEY=""

    while [[ -z "$TELEMOST_KEY" ]]; do
        printf "Enter Telemost crypto key: " >/dev/tty
        IFS= read -rs TELEMOST_KEY </dev/tty
        echo >/dev/tty
    done

    cp docs/examples/server/server.telemost.vp8channel.yaml /opt/olcrtc/server.telemost.yaml

    sed -i "s|ROOM_ID|$TELEMOST_ROOM|" /opt/olcrtc/server.telemost.yaml
    sed -i "s|CRYPTO_KEY|$TELEMOST_KEY|" /opt/olcrtc/server.telemost.yaml



fi

########################################
# Install systemd services
########################################


if [[ "$INSTALL_JITSI" == true ]]; then
    cp build/olcrtc-linux-amd64 /opt/olcrtc/
    cp /opt/olcrtc/server.jitsi.yaml /opt/olcrtc/server.jitsi.yaml
    # create olcrtc-jitsi.service
    cat > /etc/systemd/system/olcrtc-jitsi.service <<EOF
[Unit]
Description=OlcRTC Proxy Server
After=network.target network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=/opt/olcrtc
ExecStart=/opt/olcrtc/olcrtc-linux-amd64 server.jitsi.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

fi

if [[ "$INSTALL_TELEMOST" == true ]]; then
    cp build/olcrtc-linux-amd64 /opt/olcrtc/
    cp /opt/olcrtc/server.telemost.yaml /opt/olcrtc/server.telemost.yaml
    # create olcrtc-telemost.service
    cat >/etc/systemd/system/olcrtc-telemost.service <<EOF
[Unit]
Description=OlcRTC Telemost Server
After=network.target network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=/opt/olcrtc
ExecStart=/opt/olcrtc/olcrtc-linux-amd64 server.telemost.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl daemon-reload

if [[ "$INSTALL_JITSI" == true ]]; then
    systemctl enable olcrtc-jitsi.service
    systemctl start olcrtc-jitsi.service
    systemctl --no-pager --full status olcrtc-jitsi.service || true
fi

if [[ "$INSTALL_TELEMOST" == true ]]; then
    systemctl enable olcrtc-telemost.service
    systemctl start olcrtc-telemost.service
    systemctl --no-pager --full status olcrtc-telemost.service || true
fi



echo
echo "======================================"
echo "Installation completed successfully!"
echo "======================================"
echo
