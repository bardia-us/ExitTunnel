#!/bin/bash

# ====================================================
# QDTunnel Enterprise - High Performance TCP Tunnel
# Optimized for High Latency & Packet Loss Networks
# ====================================================

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- Configuration ---
CONF_DIR="/etc/qdtunnel"
TUNNELS_JSON="$CONF_DIR/tunnels.json"
SERVICE_DIR="/etc/systemd/system"
LOG_FILE="/var/log/qdtunnel_install.log"

# --- 1. System Integrity Check ---
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}[Error] Please run as root (sudo).${NC}"
        exit 1
    fi
}

install_deps() {
    echo -e "${BLUE}[*] Checking system dependencies...${NC}"
    local PKGS=""
    if ! command -v socat &> /dev/null; then PKGS="$PKGS socat"; fi
    if ! command -v jq &> /dev/null; then PKGS="$PKGS jq"; fi
    if ! command -v iptables &> /dev/null; then PKGS="$PKGS iptables"; fi
    
    if [[ -n "$PKGS" ]]; then
        echo -e "${YELLOW}[*] Installing missing packages:$PKGS ...${NC}"
        apt-get update -qq && apt-get install -y $PKGS -qq >> $LOG_FILE 2>&1
    fi
    mkdir -p "$CONF_DIR"
    if [[ ! -f "$TUNNELS_JSON" ]]; then echo "[]" > "$TUNNELS_JSON"; fi
}

# --- 2. NETWORK OPTIMIZATION (The "Pro" Part) ---
optimize_kernel() {
    echo -e "${CYAN}[*] Applying Network Optimizations (BBR + TCP Tuning)...${NC}"
    
    # 1. Enable BBR
    if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    fi

    # 2. Optimize TCP Keepalive & Buffer
    cat > /etc/sysctl.d/99-qdtunnel.conf <<EOF
fs.file-max = 1000000
net.ipv4.tcp_keepalive_time = 30
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.ip_forward = 1
EOF
    sysctl --system >> $LOG_FILE 2>&1

    # 3. FIX MTU/MSS (Crucial for Download Speed)
    # This prevents packets from being dropped by filtering equipment
    iptables -t mangle -F FORWARD 2>/dev/null
    iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
    iptables -t mangle -A OUTPUT -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1300
    
    echo -e "${GREEN}[✓] System Optimized! BBR ON | MSS Clamped to 1300${NC}"
}

# --- 3. Service Management ---
create_tunnel_service() {
    local NAME=$1
    local CMD=$2
    local SERVICE_PATH="$SERVICE_DIR/qdtunnel-${NAME}.service"

    cat > "$SERVICE_PATH" <<EOF
[Unit]
Description=QDTunnel Service - ${NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/bash -c '${CMD}'
Restart=always
RestartSec=3
LimitNOFILE=1048576
StandardOutput=append:/var/log/qdtunnel.log
StandardError=append:/var/log/qdtunnel.log

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now "qdtunnel-${NAME}"
}

# --- 4. Logic Functions ---
add_tunnel() {
    clear
    echo -e "${BLUE}=== Create New Tunnel ===${NC}"
    echo "1) IRAN Server (Bridge)"
    echo "2) KHAREJ Server (Destination)"
    read -p "Select Role [1-2]: " ROLE

    read -p "Enter Tunnel Name (e.g. v2ray_tun): " TNAME
    if [[ -z "$TNAME" ]]; then echo -e "${RED}Name required.${NC}"; sleep 1; return; fi
    
    # Check duplicate
    if grep -q "\"name\": \"$TNAME\"" "$TUNNELS_JSON"; then
        echo -e "${RED}Tunnel name exists!${NC}"; sleep 2; return;
    fi

    if [[ "$ROLE" == "1" ]]; then
        # IRAN Logic
        echo -e "\n${YELLOW}--- IRAN CONFIG ---${NC}"
        read -p "Local Port to Open (Input): " LPORT
        read -p "Kharej IP Address: " RHOST
        read -p "Kharej Port (Output): " RPORT
        
        # PRO Command with TCP Optimization flags
        CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork,keepalive,rcvbuf=65536,sndbuf=65536 TCP:${RHOST}:${RPORT},keepalive,rcvbuf=65536,sndbuf=65536"
        
        create_tunnel_service "$TNAME" "$CMD"
        
        # Save to DB
        jq ". += [{\"name\": \"$TNAME\", \"role\": \"IRAN\", \"port\": \"$LPORT -> $RHOST:$RPORT\"}]" "$TUNNELS_JSON" > "$TUNNELS_JSON.tmp" && mv "$TUNNELS_JSON.tmp" "$TUNNELS_JSON"
        echo -e "${GREEN}[✓] Iran tunnel started on port $LPORT${NC}"

    elif [[ "$ROLE" == "2" ]]; then
        # KHAREJ Logic
        echo -e "\n${YELLOW}--- KHAREJ CONFIG ---${NC}"
        read -p "Listen Port (Input from Iran): " LPORT
        read -p "Target IP (Usually 127.0.0.1): " RHOST
        read -p "Target Port (V2Ray Port): " RPORT

        CMD="socat TCP-LISTEN:${LPORT},reuseaddr,fork,keepalive,rcvbuf=65536,sndbuf=65536 TCP:${RHOST}:${RPORT},keepalive,rcvbuf=65536,sndbuf=65536"
        
        create_tunnel_service "$TNAME" "$CMD"
        
        jq ". += [{\"name\": \"$TNAME\", \"role\": \"KHAREJ\", \"port\": \"$LPORT -> $RHOST:$RPORT\"}]" "$TUNNELS_JSON" > "$TUNNELS_JSON.tmp" && mv "$TUNNELS_JSON.tmp" "$TUNNELS_JSON"
        echo -e "${GREEN}[✓] Kharej tunnel listening on port $LPORT${NC}"
    fi
    sleep 2
}

list_tunnels() {
    clear
    echo -e "${BLUE}=== Active Tunnels ===${NC}"
    if [[ ! -s "$TUNNELS_JSON" || "$(cat $TUNNELS_JSON)" == "[]" ]]; then
        echo "No tunnels found."
    else
        printf "%-15s %-10s %-30s %-10s\n" "NAME" "ROLE" "ROUTING" "STATUS"
        echo "----------------------------------------------------------------"
        jq -r '.[] | "\(.name) \(.role) \(.port)"' "$TUNNELS_JSON" | while read -r name role port; do
            STATUS=$(systemctl is-active "qdtunnel-$name")
            if [[ "$STATUS" == "active" ]]; then
                COLOR=$GREEN
            else
                COLOR=$RED
            fi
            printf "%-15s %-10s %-30s ${COLOR}%-10s${NC}\n" "$name" "$role" "$port" "$STATUS"
        done
    fi
    echo ""
    read -p "Press Enter..."
}

remove_tunnel() {
    clear
    echo -e "${BLUE}=== Remove Tunnel ===${NC}"
    jq -r '.[] | .name' "$TUNNELS_JSON"
    echo ""
    read -p "Enter name to delete: " TNAME
    if [[ -z "$TNAME" ]]; then return; fi

    systemctl stop "qdtunnel-$TNAME" 2>/dev/null
    systemctl disable "qdtunnel-$TNAME" 2>/dev/null
    rm "$SERVICE_DIR/qdtunnel-$TNAME.service" 2>/dev/null
    systemctl daemon-reload
    
    jq "map(select(.name != \"$TNAME\"))" "$TUNNELS_JSON" > "$TUNNELS_JSON.tmp" && mv "$TUNNELS_JSON.tmp" "$TUNNELS_JSON"
    echo -e "${GREEN}[✓] Tunnel $TNAME removed.${NC}"
    sleep 1
}

fix_network_issues() {
    optimize_kernel
    echo -e "${YELLOW}[*] Restarting all tunnels to apply changes...${NC}"
    jq -r '.[] | .name' "$TUNNELS_JSON" | while read -r name; do
        systemctl restart "qdtunnel-$name"
    done
    echo -e "${GREEN}[✓] Network Fixed & Tunnels Restarted.${NC}"
    read -p "Press Enter..."
}

# --- 5. Main Loop ---
check_root
install_deps

while true; do
    clear
    echo -e "${CYAN}===================================${NC}"
    echo -e "${CYAN}   QDTunnel Enterprise Manager     ${NC}"
    echo -e "${CYAN}===================================${NC}"
    echo "1. Create New Tunnel"
    echo "2. List & Check Status"
    echo "3. Remove Tunnel"
    echo -e "${YELLOW}4. FORCE FIX NETWORK (Run this for Download Fix)${NC}"
    echo "0. Exit"
    echo "-----------------------------------"
    read -p "Select Option: " OPT

    case $OPT in
        1) add_tunnel ;;
        2) list_tunnels ;;
        3) remove_tunnel ;;
        4) fix_network_issues ;;
        0) exit 0 ;;
        *) echo "Invalid option" ;;
    esac
done

