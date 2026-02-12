#!/bin/bash

# ====================================================
#  GEMINI TUNNEL (Based on GOST V3)
#  Modes: WebSocket (Reliable) | gRPC (Fast)
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
        echo -e "${RED}[!] Please run as root.${NC}"
        exit 1
    fi
}

install_gost_v3() {
    if command -v gost &> /dev/null; then
        # Check version
        VER=$(gost -V 2>&1)
        if [[ "$VER" == *"gost 3"* ]]; then
            echo -e "${GREEN}[✓] GOST V3 is already installed.${NC}"
            return
        fi
    fi

    echo -e "${BLUE}[*] Installing GOST V3...${NC}"
    rm -f /usr/local/bin/gost
    
    ARCH=$(dpkg --print-architecture)
    if [[ "$ARCH" == "amd64" ]]; then
        URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_amd64.tar.gz"
    elif [[ "$ARCH" == "arm64" ]]; then
        URL="https://github.com/go-gost/gost/releases/download/v3.0.0/gost_3.0.0_linux_arm64.tar.gz"
    else
        echo -e "${RED}Architecture $ARCH not supported automatically.${NC}"
        exit 1
    fi

    wget -q --show-progress "$URL" -O /tmp/gost.tar.gz
    tar -xzvf /tmp/gost.tar.gz -C /tmp/
    mv /tmp/gost /usr/local/bin/
    chmod +x /usr/local/bin/gost
    rm /tmp/gost.tar.gz
    echo -e "${GREEN}[✓] GOST V3 Installed!${NC}"
}

setup_kharej() {
    echo -e "\n${YELLOW}--- KHAREJ SETUP (DESTINATION) ---${NC}"
    echo "1) WebSocket (Most Reliable - Use this if UDP failed)"
    echo "2) gRPC (Faster but sometimes blocked)"
    read -p "Select Protocol [1-2]: " PROTO
    
    read -p "Tunnel Port (Input from Iran, e.g. 8080): " TUN_PORT
    read -p "Target IP (Where is Config? usually 127.0.0.1): " TARGET_IP
    read -p "Target Port (Config Port, e.g. 2053): " TARGET_PORT

    if [[ "$PROTO" == "1" ]]; then
        # WebSocket Listener
        # Pattern: -L ws://:8080?path=/tun&forward=tcp://127.0.0.1:2053
        CMD="$GOST_PATH -L ws://:$TUN_PORT?path=/tun&forward=tcp://$TARGET_IP:$TARGET_PORT"
        NAME="ws"
    else
        # gRPC Listener
        CMD="$GOST_PATH -L grpc://:$TUN_PORT?forward=tcp://$TARGET_IP:$TARGET_PORT"
        NAME="grpc"
    fi

    create_service "kharej" "$CMD"
    echo -e "${GREEN}[✓] Kharej ($NAME) listening on port $TUN_PORT${NC}"
    echo -e "${RED}[IMPORTANT] Ensure port $TUN_PORT is open in Firewall!${NC}"
}

setup_iran() {
    echo -e "\n${YELLOW}--- IRAN SETUP (BRIDGE) ---${NC}"
    echo "1) WebSocket (Must match Kharej)"
    echo "2) gRPC (Must match Kharej)"
    read -p "Select Protocol [1-2]: " PROTO
    
    read -p "Local Port (User Connects here, e.g. 443): " USER_PORT
    read -p "Kharej IP Address: " KHAREJ_IP
    read -p "Kharej Tunnel Port (Port you set on Kharej): " TUN_PORT

    if [[ "$PROTO" == "1" ]]; then
        # WebSocket Forwarder
        # Pattern: -L tcp://:443 -F ws://KHAREJ:PORT?path=/tun
        CMD="$GOST_PATH -L tcp://:$USER_PORT -F ws://$KHAREJ_IP:$TUN_PORT?path=/tun"
    else
        # gRPC Forwarder
        CMD="$GOST_PATH -L tcp://:$USER_PORT -F grpc://$KHAREJ_IP:$TUN_PORT"
    fi

    create_service "iran" "$CMD"
    echo -e "${GREEN}[✓] Iran Bridge started on port $USER_PORT${NC}"
}

create_service() {
    local TYPE=$1
    local EXEC=$2
    local SFILE="$SERVICE_DIR/gost-$TYPE.service"

    cat > "$SFILE" <<EOF
[Unit]
Description=GOST V3 Tunnel ($TYPE)
After=network.target

[Service]
ExecStart=$EXEC
Restart=always
User=root
LimitNOFILE=1048576
StandardOutput=append:/var/log/gost.log
StandardError=append:/var/log/gost.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "gost-$TYPE"
}

check_status() {
    echo -e "\n${BLUE}--- SERVICE STATUS ---${NC}"
    if systemctl is-active --quiet gost-kharej; then
        echo -e "KHAREJ Service: ${GREEN}RUNNING${NC}"
        echo "Logs (Last 5 lines):"
        tail -n 5 /var/log/gost.log
    elif systemctl is-active --quiet gost-iran; then
        echo -e "IRAN Service: ${GREEN}RUNNING${NC}"
        echo "Logs (Last 5 lines):"
        tail -n 5 /var/log/gost.log
    else
        echo -e "Service: ${RED}STOPPED${NC}"
        echo "Check logs at /var/log/gost.log"
    fi
    echo ""
    read -p "Press Enter..."
}

remove_tunnel() {
    systemctl stop gost-kharej gost-iran 2>/dev/null
    systemctl disable gost-kharej gost-iran 2>/dev/null
    rm "$SERVICE_DIR/gost-kharej.service" 2>/dev/null
    rm "$SERVICE_DIR/gost-iran.service" 2>/dev/null
    systemctl daemon-reload
    echo -e "${GREEN}[✓] Removed.${NC}"
    sleep 1
}

# --- Main ---
check_root
install_gost_v3

while true; do
    clear
    echo -e "${CYAN}=== GEMINI TUNNEL (GOST V3) ===${NC}"
    echo "1. Setup KHAREJ (Destination)"
    echo "2. Setup IRAN (Bridge)"
    echo "3. Check Logs & Status (DEBUG)"
    echo "4. Remove Tunnel"
    echo "0. Exit"
    echo "-------------------------------"
    read -p "Select: " OPT
    case $OPT in
        1) setup_kharej; read -p "Press Enter..." ;;
        2) setup_iran; read -p "Press Enter..." ;;
        3) check_status ;;
        4) remove_tunnel ;;
        0) exit 0 ;;
        *) echo "Invalid" ;;
    esac
done
