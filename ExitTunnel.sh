#!/bin/bash

# ====================================================
#  QUIC-GOST TUNNEL - NEXT GEN 🚀
#  Simple, Fast, Encrypted Tunnel using GOST v2
# ====================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Config ---
GOST_PATH="/usr/local/bin/gost"
SERVICE_DIR="/etc/systemd/system"

# --- Functions ---

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}Please run as root!${NC}"
        exit 1
    fi
}

install_gost() {
    if command -v gost &> /dev/null; then
        echo -e "${GREEN}GOST is already installed.${NC}"
        return
    fi

    echo -e "${BLUE}[*] Detecting Architecture...${NC}"
    ARCH=$(uname -m)
    if [[ "$ARCH" == "x86_64" ]]; then
        URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-amd64-2.11.5.gz"
    elif [[ "$ARCH" == "aarch64" ]]; then
        URL="https://github.com/ginuerzh/gost/releases/download/v2.11.5/gost-linux-arm64-2.11.5.gz"
    else
        echo -e "${RED}Architecture $ARCH not supported automatically.${NC}"
        return
    fi

    echo -e "${YELLOW}[*] Downloading GOST (The Beast)...${NC}"
    wget -q --show-progress "$URL" -O /tmp/gost.gz
    gzip -d /tmp/gost.gz
    mv /tmp/gost /usr/local/bin/
    chmod +x /usr/local/bin/gost
    echo -e "${GREEN}[✓] GOST Installed Successfully!${NC}"
}

setup_kharej() {
    echo -e "\n${YELLOW}--- KHAREJ SERVER SETUP (DESTINATION) ---${NC}"
    echo "This server will receive traffic via QUIC and send it to your V2Ray/Config."
    
    read -p "Enter Tunnel Port (UDP port to listen on, e.g., 443 or 8443): " TUN_PORT
    read -p "Enter Target Port (Where is V2Ray listening? e.g., 2053): " TARGET_PORT
    
    # Validation
    if [[ -z "$TUN_PORT" || -z "$TARGET_PORT" ]]; then echo "${RED}Invalid inputs!${NC}"; return; fi

    SERVICE_FILE="$SERVICE_DIR/gost-kharej.service"
    
    # Command: Listen on QUIC, Forward to Localhost TCP
    CMD="$GOST_PATH -L=quic://:$TUN_PORT/127.0.0.1:$TARGET_PORT"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST QUIC Tunnel (Kharej)
After=network.target

[Service]
ExecStart=$CMD
Restart=always
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now gost-kharej
    echo -e "${GREEN}[✓] Kharej Tunnel Started on UDP Port $TUN_PORT${NC}"
    echo -e "${CYAN}Make sure port $TUN_PORT (UDP) is open in firewall!${NC}"
}

setup_iran() {
    echo -e "\n${YELLOW}--- IRAN SERVER SETUP (BRIDGE) ---${NC}"
    echo "This server will accept user connections and fly them to Kharej via QUIC."
    
    read -p "Enter Local Port (User connects here, e.g., 8080): " USER_PORT
    read -p "Enter Kharej IP Address: " KHAREJ_IP
    read -p "Enter Kharej Tunnel Port (The QUIC port, e.g., 443): " TUN_PORT
    
    # Validation
    if [[ -z "$USER_PORT" || -z "$KHAREJ_IP" || -z "$TUN_PORT" ]]; then echo "${RED}Invalid inputs!${NC}"; return; fi

    SERVICE_FILE="$SERVICE_DIR/gost-iran.service"
    
    # Command: Listen TCP, Forward QUIC (Insecure to skip cert check)
    CMD="$GOST_PATH -L=tcp://:$USER_PORT -F=quic://$KHAREJ_IP:$TUN_PORT?keepalive=true&noverify=true"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST QUIC Tunnel (Iran)
After=network.target

[Service]
ExecStart=$CMD
Restart=always
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now gost-iran
    echo -e "${GREEN}[✓] Iran Tunnel Started on Port $USER_PORT${NC}"
    echo -e "${BLUE}Users should connect to THIS server IP on port $USER_PORT${NC}"
}

remove_tunnel() {
    echo -e "${RED}[!] Stopping and Removing Services...${NC}"
    systemctl stop gost-kharej 2>/dev/null
    systemctl disable gost-kharej 2>/dev/null
    rm "$SERVICE_DIR/gost-kharej.service" 2>/dev/null
    
    systemctl stop gost-iran 2>/dev/null
    systemctl disable gost-iran 2>/dev/null
    rm "$SERVICE_DIR/gost-iran.service" 2>/dev/null
    
    systemctl daemon-reload
    echo -e "${GREEN}[✓] Cleaned up.${NC}"
}

# --- Main Menu ---
check_root
install_gost

while true; do
    clear
    echo -e "${CYAN}==============================${NC}"
    echo -e "${CYAN}   QUIC TUNNEL MANAGER (GOST) ${NC}"
    echo -e "${CYAN}==============================${NC}"
    echo "1. Setup KHAREJ (Destination)"
    echo "2. Setup IRAN (Bridge)"
    echo "3. Remove Tunnel"
    echo "0. Exit"
    echo "------------------------------"
    read -p "Select: " OPT

    case $OPT in
        1) setup_kharej; read -p "Press Enter..." ;;
        2) setup_iran; read -p "Press Enter..." ;;
        3) remove_tunnel; read -p "Press Enter..." ;;
        0) exit 0 ;;
        *) echo "Invalid" ;;
    esac
done
