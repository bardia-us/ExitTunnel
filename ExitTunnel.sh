#!/bin/bash

# ==============================================================================
# ExitTunnel Manager - Developed by @mr_bxs
# ==============================================================================
# This script sets up a secure and persistent VXLAN tunnel between two servers.
# It includes automatic "dekomodor" (traffic redirection) on the Iran server
# and sets up the Foreign server as the internet gateway with Sanayi/X-UI.
#
# Features: VXLAN tunnel, automatic public port redirection to VXLAN (Iran side),
# persistent services via systemd, 'exittunnel' command, BBR, cronjob.
#
# GitHub: [Upload to GitHub & put your link here]
# Telegram ID: @mr_bxs
# Script Version: 12.0 (Final - VXLAN with Auto-Dekomodor)
# ==============================================================================

# --- Global Variables & Configuration ---
LOG_FILE="/var/log/exittunnel.log"
CONFIG_BASE_DIR="/etc/exittunnel" # Base directory for all ExitTunnel configs
# VXLAN parameters (fixed for simplicity, can be made user-configurable if needed)
VNI=88 # VXLAN Network Identifier - A unique ID for your VXLAN tunnel
VXLAN_IF="vxlan${VNI}" # Name of the VXLAN interface
IRAN_VXLAN_IP="30.0.0.1/24" # Internal IP for Iran side
KHAREJ_VXLAN_IP="30.0.0.2/24" # Internal IP for Foreign side
SCRIPT_VERSION="12.0"
PERSISTENT_SCRIPT_PATH="/usr/local/bin/exittunnel-core.sh" # Path where script will be stored
SYMLINK_PATH="/usr/local/bin/exittunnel" # Command to run the script

# ---------------- COLORS ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m'

# ---------------- FUNCTIONS ----------------

# --- Helper Functions ---
function get_public_ipv4() {
    local ip=$(curl -s4 --connect-timeout 5 "https://api.ipify.org" || \
               curl -s4 --connect-timeout 5 "https://ipv4.icanhazip.com" || \
               curl -s4 --connect-timeout 5 "http://ifconfig.me/ip")
    echo "${ip:-N/A}"
}

function get_public_ipv6() {
    local ip6=$(curl -s6 --connect-timeout 5 "https://api6.ipify.org" || \
                curl -s6 --connect-timeout 5 "https://ipv6.icanhazip.com" || \
                curl -s6 --connect-timeout 5 "http://ifconfig.me/ip")
    echo "${ip6:-N/A}"
}

function log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

function press_enter_to_continue() {
    echo -e "${BLUE}Press Enter to continue...${NC}"
    read -r
}

# --- Menu Display Function ---
function display_main_menu() {
    clear
    local current_ip=$(get_public_ipv4)
    local country=$(curl -sS --connect-timeout 5 "http://ip-api.com/json/$current_ip" | jq -r '.country' 2>/dev/null || echo "N/A")
    local isp=$(curl -sS --connect-timeout 5 "http://ip-api.com/json/$current_ip" | jq -r '.isp' 2>/dev/null || echo "N/A")

    echo -e "${CYAN}-------------------------------------------------------------------------${NC}"
    echo -e "${YELLOW} ExitTunnel Manager by @mr_bxs ${NC}"
    echo -e "${CYAN}-------------------------------------------------------------------------${NC}"
    echo -e "${GREEN}Server Country |${NC} $country"
    echo -e "${GREEN}Server IP |${NC} $current_ip"
    echo -e "${GREEN}Server ISP |${NC} $isp"
    echo -e "${CYAN}-------------------------------------------------------------------------${NC}"
    echo -e "${YELLOW}Please choose an option:${NC}"
    echo -e "${GREEN}1. Install ExitTunnel (New Setup)${NC}"
    echo -e "${BLUE}2. Manage ExitTunnel Services${NC}"
    echo -e "${PURPLE}3. Advanced Tools (BBR, Cronjob)${NC}"
    echo -e "${RED}4. Uninstall All ExitTunnel Components${NC}"
    echo -e "${WHITE}5. Exit${NC}"
    echo -e "${CYAN}-------------------------------------------------------------------------${NC}"
    read -p "$(echo -e "${BLUE}Your choice: ${NC}")" choice
}

# --- Core Installation Functions ---
function install_dependencies() {
    echo -e "${YELLOW}Checking and installing prerequisites...${NC}"
    log_action "Starting dependency installation."

    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y > /dev/null 2>&1 || log_action "Warning: apt update failed."
        sudo apt-get install -y iproute2 net-tools grep awk sudo iputils-ping jq curl haproxy iptables iptables-persistent > /dev/null 2>&1
    elif command -v yum &> /dev/null; then
        sudo yum install -y iproute2 net-tools grep awk sudo iputils-ping jq curl haproxy iptables iptables-services > /dev/null 2>&1
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y iproute2 net-tools grep awk sudo iputils-ping jq curl haproxy iptables iptables-services > /dev/null 2>&1
    else
        echo -e "${RED}Error: Supported package manager (apt, yum, dnf) not found. Please install dependencies manually.${NC}"
        log_action "❌ Package manager not detected for dependency installation."
        press_enter_to_continue
        return 1
    fi

    # Verify essential commands are available
    if ! command -v ip >/dev/null 2>&1; then echo -e "${RED}Error: 'iproute2' not installed. Aborting.${NC}"; log_action "❌ iproute2 not found after install."; press_enter_to_continue; return 1; fi
    if ! command -v jq >/dev/null 2>&1; then echo -e "${RED}Error: 'jq' not installed. Aborting.${NC}"; log_action "❌ jq not found after install."; press_enter_to_continue; return 1; fi
    if ! command -v haproxy >/dev/null 2>&1; then echo -e "${RED}Error: 'haproxy' not installed. Aborting.${NC}"; log_action "❌ haproxy not found after install."; press_enter_to_continue; return 1; fi
    
    echo -e "${GREEN}All essential dependencies installed successfully.${NC}"
    log_action "✅ All essential dependencies installed."
    return 0
}

# --- Uninstall Functions ---
function uninstall_all_exittunnel_components() {
    echo -e "${YELLOW}Starting complete ExitTunnel uninstallation...${NC}"
    log_action "Initiating full ExitTunnel uninstall."
    
    # Stop and disable all VXLAN tunnel services
    echo -e "${YELLOW}Stopping and disabling VXLAN tunnel services...${NC}"
    for service_file in /etc/systemd/system/vxlan-tunnel.service; do # Only one VXLAN service
        if [ -f "$service_file" ]; then
            systemctl stop vxlan-tunnel.service > /dev/null 2>&1
            systemctl disable vxlan-tunnel.service > /dev/null 2>&1
            rm -f "$service_file"
            log_action "Stopped and removed VXLAN service: vxlan-tunnel.service"
        fi
    done
    rm -f /usr/local/bin/vxlan_bridge.sh # Remove the helper script

    echo -e "${YELLOW}Stopping and disabling HAProxy service...${NC}"
    systemctl stop haproxy 2>/dev/null
    systemctl disable haproxy 2>/dev/null
    
    echo -e "${YELLOW}Removing HAProxy package and configs...${NC}"
    if command -v apt-get &> /dev/null; then
        sudo apt-get remove -y haproxy > /dev/null 2>&1
        sudo apt-get purge -y haproxy > /dev/null 2>&1
        sudo apt-get autoremove -y > /dev/null 2>&1
    elif command -v yum &> /dev/null || command -v dnf &> /dev/null; then
        sudo yum remove -y haproxy > /dev/null 2>&1
        sudo yum autoremove -y > /dev/null 2>&1
    fi
    rm -rf /etc/haproxy # Remove HAProxy config directory
    log_action "Removed haproxy package and configs."

    echo -e "${YELLOW}Removing ExitTunnel configuration directory...${NC}"
    rm -rf "$CONFIG_BASE_DIR"
    log_action "Removed ExitTunnel config base directory."
    
    # Restore iptables to original state (from backup or default)
    echo -e "${YELLOW}Restoring iptables rules...${NC}"
    log_action "Restoring iptables rules."
    if [ -f /etc/iptables/rules.v4.bak ]; then
        sudo iptables-restore < /etc/iptables/rules.v4.bak > /dev/null 2>&1
        log_action "Restored IPv4 iptables from backup."
    else # Fallback to flush if no backup
        sudo iptables -F > /dev/null 2>&1 # Flush all rules
        sudo iptables -X > /dev/null 2>&1 # Delete all non-default chains
        sudo iptables -P INPUT ACCEPT > /dev/null 2>&1
        sudo iptables -P FORWARD ACCEPT > /dev/null 2>&1
        sudo iptables -P OUTPUT ACCEPT > /dev/null 2>&1
        log_action "Flushed iptables rules (no backup found)."
    fi
    # Also for IPv6 if needed (though VXLAN is typically IPv4)
    if [ -f /etc/iptables/rules.v6.bak ]; then
        sudo ip6tables-restore < /etc/iptables/rules.v6.bak > /dev/null 2>&1
        log_action "Restored IPv6 iptables from backup."
    else
        sudo ip6tables -F > /dev/null 2>&1
        sudo ip6tables -X > /dev/null 2>&1
        sudo ip6tables -P INPUT ACCEPT > /dev/null 2>&1
        sudo ip6tables -P FORWARD ACCEPT > /dev/null 2>&1
        sudo ip6tables -P OUTPUT ACCEPT > /dev/null 2>&1
    fi
    # Ensure IP forwarding is disabled if no other service requires it
    sudo sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1
    sudo netfilter-persistent save > /dev/null 2>&1
    log_action "✅ iptables rules reset and saved."

    # Remove related cronjobs
    echo -e "${YELLOW}Removing related cronjobs...${NC}"
    crontab -l 2>/dev/null | grep -v 'systemctl restart haproxy' | grep -v 'systemctl restart vxlan-tunnel' | grep -v '/sbin/iptables-restore' > /tmp/cron_tmp || true
    crontab /tmp/cron_tmp
    rm -f /tmp/cron_tmp
    log_action "Removed related cronjobs."

    systemctl daemon-reload # Reload systemd after changes
    echo -e "${GREEN}All ExitTunnel components uninstalled and cleanup completed.${NC}"
    log_action "✅ ExitTunnel uninstallation complete."
    press_enter_to_continue
}

# --- Advanced Tools Functions ---
function install_bbr_script() {
    echo -e "${YELLOW}Running BBR installation script...${NC}"
    log_action "Starting BBR installation."
    curl -fsSL https://raw.githubusercontent.com/MrAminiDev/NetOptix/main/scripts/bbr.sh -o /tmp/bbr.sh
    if [ $? -eq 0 ]; then
        bash /tmp/bbr.sh
        echo -e "${GREEN}BBR installation script executed. Check system for BBR status.${NC}"
    else
        echo -e "${RED}Failed to download BBR script. Please check your internet connection.${NC}"
    fi
    rm -f /tmp/bbr.sh
    log_action "✅ BBR installation script executed."
    press_enter_to_continue
}

function install_restart_cronjob() {
    echo -e "${YELLOW}Setting up cronjob for automatic service restarts...${NC}"
    while true; do
        read -p "How many hours between each restart? (1-24): " cron_hours
        if [[ $cron_hours =~ ^[0-9]+$ ]] && (( cron_hours >= 1 && cron_hours <= 24 )); then
            break
        else
            echo -e "${RED}Invalid input. Please enter a number between 1 and 24.${NC}"
        fi
    done
    log_action "Setting up cronjob for restarts every $cron_hours hour(s)."
    
    # Remove any previous cronjobs for these services
    crontab -l 2>/dev/null | grep -v 'systemctl restart haproxy' | grep -v 'systemctl restart vxlan-tunnel' | grep -v '/sbin/iptables-restore' > /tmp/cron_tmp || true
    echo "0 */$cron_hours * * * systemctl restart haproxy >/dev/null 2>&1" >> /tmp/cron_tmp
    echo "0 */$cron_hours * * * systemctl restart vxlan-tunnel >/dev/null 2>&1" >> /tmp/cron_tmp
    echo "0 */$cron_hours * * * /sbin/iptables-restore < /etc/iptables/rules.v4 >/dev/null 2>&1" >> /tmp/cron_tmp # Restore iptables
    crontab /tmp/cron_tmp
    rm -f /tmp/cron_tmp
    echo -e "${GREEN}Cronjob set successfully to restart HAProxy and VXLAN tunnel every $cron_hours hour(s).${NC}"
    log_action "✅ Cronjob configured."
    press_enter_to_continue
}

# --- Tunnel Management Functions ---

# Function to configure HAProxy for port forwarding (Auto-Dekomodor) on Iran Server
function configure_haproxy_port_forwarding() {
    echo -e "${YELLOW}Configuring HAProxy for automatic port forwarding (Auto-Dekomodor) on Iran Server...${NC}"
    log_action "Starting HAProxy configuration for port forwarding."

    # Ensure haproxy is installed (it should be from dependencies)
    if ! command -v haproxy >/dev/null 2>&1; then
        echo -e "${RED}Error: HAProxy is not installed. Please install it first or run 'Install ExitTunnel (New Setup)'.${NC}"
        log_action "❌ HAProxy not found for configuration."
        press_enter_to_continue
        return 1
    fi

    sudo mkdir -p /etc/haproxy
    local CONFIG_FILE="/etc/haproxy/haproxy.cfg"
    local BACKUP_FILE="/etc/haproxy/haproxy.cfg.bak"

    # Backup old config only if it's not our template
    if [ -f "$CONFIG_FILE" ]; then
        if ! grep -q "### ExitTunnel HAProxy Config ###" "$CONFIG_FILE"; then
            cp "$CONFIG_FILE" "$BACKUP_FILE"
            log_action "Backed up existing HAProxy config to $BACKUP_FILE"
        fi
    fi

    # Write base config for HAProxy
    cat <<EOL > "$CONFIG_FILE"
### ExitTunnel HAProxy Config ###
global
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 4096

defaults
    mode tcp
    option dontlognull
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms
    retries 3
    option tcpka
EOL
    
    local local_public_ip=$(hostname -I | awk '{print $1}' | head -n1)
    local vxlan_internal_ip="${KHAREJ_VXLAN_IP%/*}" # This will be 30.0.0.2

    read -p "Enter public ports on this server (Iran) to forward (comma-separated, e.g., 80,443): " user_public_ports
    IFS=',' read -ra public_ports_array <<< "$user_public_ports"

    if [ ${#public_ports_array[@]} -eq 0 ]; then
        echo -e "${RED}No ports entered. HAProxy configuration aborted.${NC}"
        log_action "❌ No ports entered for HAProxy configuration."
        press_enter_to_continue
        return 1
    fi

    for public_port in "${public_ports_array[@]}"; do
        if ! [[ "$public_port" =~ ^[0-9]+$ ]] || [ "$public_port" -lt 1 ] || [ "$public_port" -gt 65535 ]; then
            echo -e "${RED}Invalid port number '$public_port' ignored. Only numbers between 1 and 65535 are allowed.${NC}"
            continue
        fi
        cat <<EOL >> "$CONFIG_FILE"

frontend frontend_$public_port
    bind $local_public_ip:$public_port # Bind to public IP
    default_backend backend_$public_port
    option tcpka

backend backend_$public_port
    option tcpka
    server server1 $vxlan_internal_ip:$public_port check maxconn 2048 # Forward to VXLAN internal IP (30.0.0.2)
EOL
    done

    # Validate haproxy config
    if haproxy -c -f "$CONFIG_FILE"; then
        echo -e "${YELLOW}Restarting HAProxy service...${NC}"
        systemctl restart haproxy
        systemctl enable haproxy
        if systemctl is-active --quiet haproxy; then
            echo -e "${GREEN}HAProxy configured and restarted successfully for port forwarding.${NC}"
            log_action "✅ HAProxy configured and restarted."
        else
            echo -e "${RED}Failed to start HAProxy service. Check logs with 'sudo systemctl status haproxy'.${NC}"
            log_action "❌ HAProxy failed to start after configuration."
            [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$CONFIG_FILE" && systemctl restart haproxy && log_action "Attempted to restore HAProxy config from backup."
        fi
    else
        echo -e "${RED}Warning: HAProxy configuration is invalid! Attempting to restore backup or clean up.${NC}"
        log_action "HAProxy config validation failed."
        [ -f "$BACKUP_FILE" ] && cp "$BACKUP_FILE" "$CONFIG_FILE" && systemctl restart haproxy && log_action "Attempted to restore HAProxy config from backup."
    fi
    press_enter_to_continue
}

# Core logic for installing a new VXLAN tunnel role
function install_new_tunnel() {
    echo -e "${YELLOW}Starting new ExitTunnel setup...${NC}"
    log_action "Initiating new tunnel setup."
    
    if ! install_dependencies; then
        echo -e "${RED}Aborting tunnel setup due to dependency installation failure.${NC}"
        return
    fi

    # ------------- VARIABLES --------------
    local role_choice=""
    local REMOTE_IP="" # Public IP of the other server
    local MY_VXLAN_IP="" # Internal VXLAN IP for this server
    local DSTPORT="" # VXLAN tunnel port

    echo -e "${BLUE}Choose server role:${NC}"
    echo -e " 1- ${GREEN}Iran (Border Server with Auto-Dekomodor and HAProxy)${NC}"
    echo -e " 2- ${GREEN}Kharej (Main Server with Sanayi/X-UI)${NC}"
    read -p "$(echo -e "${BLUE}Enter choice (1/2): ${NC}")" role_choice

    if [[ "$role_choice" == "1" ]]; then # Iran Server
        read -p "Enter Foreign Server Public IP (Kharej IP): " KHAREJ_IP
        if [ -z "$KHAREJ_IP" ]; then echo -e "${RED}IP cannot be empty.${NC}"; press_enter_to_continue; return; fi

        read -p "Enter Tunnel Port (e.g., 4789 - standard VXLAN UDP port): " DSTPORT
        while true; do
            if [[ "$DSTPORT" =~ ^[0-9]+$ ]] && (( DSTPORT >= 1 && DSTPORT <= 65535 )); then break; fi
            echo -e "${RED}Invalid port. Please enter a number between 1 and 65535.${NC}"
            read -p "Tunnel port: " DSTPORT
        done
        
        MY_VXLAN_IP=$IRAN_VXLAN_IP
        REMOTE_IP=$KHAREJ_IP
        log_action "Configuring Iran Server (Forwarder)."

        # This will internally call configure_haproxy_port_forwarding
        echo -e "${MAGENTA}After VXLAN setup, you will be prompted to configure HAProxy for public port forwarding.${NC}"

    elif [[ "$role_choice" == "2" ]]; then # Kharej Server
        read -p "Enter Iran Server Public IP (IRAN IP): " IRAN_IP
        if [ -z "$IRAN_IP" ]; then echo -e "${RED}IP cannot be empty.${NC}"; press_enter_to_continue; return; fi

        read -p "Enter Tunnel Port (e.g., 4789 - Must match Iran Server's Tunnel Port): " DSTPORT
        while true; do
            if [[ "$DSTPORT" =~ ^[0-9]+$ ]] && (( DSTPORT >= 1 && DSTPORT <= 65535 )); then break; fi
            echo -e "${RED}Invalid port. Please enter a number between 1 and 65535.${NC}"
            read -p "Tunnel port: " DSTPORT
        done

        MY_VXLAN_IP=$KHAREJ_VXLAN_IP
        REMOTE_IP=$IRAN_IP
        log_action "Configuring Kharej Server (Receiver)."

    else
        echo -e "${RED}Invalid role selected. Aborting tunnel setup.${NC}"
        press_enter_to_continue
        return
    fi

    # Detect default interface for VXLAN
    local INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5}' | head -n1)
    if [ -z "$INTERFACE" ]; then
        echo -e "${RED}Error: Could not detect main network interface. Aborting VXLAN setup.${NC}"
        log_action "❌ Main network interface not detected."
        press_enter_to_continue
        return
    fi
    log_action "Detected main interface: $INTERFACE"


    # ------------ Setup VXLAN Interface --------------
    echo -e "${YELLOW}Creating VXLAN interface ${VXLAN_IF}...${NC}"
    log_action "Creating VXLAN interface."
    # Ensure the interface is not already present before adding
    sudo ip link del "$VXLAN_IF" 2>/dev/null
    sudo ip link add "$VXLAN_IF" type vxlan id "$VNI" local "$(hostname -I | awk '{print $1}' | head -n1)" remote "$REMOTE_IP" dev "$INTERFACE" dstport "$DSTPORT" nolearning
    
    echo -e "${YELLOW}Assigning IP ${MY_VXLAN_IP} to ${VXLAN_IF}...${NC}"
    sudo ip addr add "$MY_VXLAN_IP" dev "$VXLAN_IF"
    sudo ip link set "$VXLAN_IF" up
    log_action "VXLAN interface configured and brought up."

    # ------------ Setup IPTables Rules --------------
    echo -e "${YELLOW}Adding iptables rules for VXLAN tunnel on port ${DSTPORT}...${NC}"
    log_action "Adding iptables rules."
    # Backup existing iptables rules before adding new ones
    sudo iptables-save > /etc/iptables/rules.v4.bak
    if command -v ip6tables-save >/dev/null 2>&1; then
        sudo ip6tables-save > /etc/iptables/rules.v6.bak
    fi

    # Always enable IP forwarding for both servers in a tunnel setup
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    log_action "Enabled IPv4 forwarding."
    
    # Clear existing INPUT rules that might conflict (be careful with existing setups)
    # It's safer to add specific rules than to fully flush if other services exist.
    sudo iptables -D INPUT -p udp --dport "$DSTPORT" -j ACCEPT 2>/dev/null || true # Remove if exists
    sudo iptables -D INPUT -s "$REMOTE_IP" -j ACCEPT 2>/dev/null || true # Remove if exists
    if [[ "$role_choice" == "1" ]]; then # Iran server
        sudo iptables -D INPUT -s ${KHAREJ_VXLAN_IP%/*} -j ACCEPT 2>/dev/null || true # Remove if exists
    elif [[ "$role_choice" == "2" ]]; then # Kharej server
        sudo iptables -D INPUT -s ${IRAN_VXLAN_IP%/*} -j ACCEPT 2>/dev/null || true # Remove if exists
    fi

    # Add rules to accept VXLAN traffic
    sudo iptables -A INPUT -p udp --dport "$DSTPORT" -j ACCEPT # Accept UDP traffic on the VXLAN port
    sudo iptables -A INPUT -s "$REMOTE_IP" -j ACCEPT # Accept traffic from the remote public IP
    if [[ "$role_choice" == "1" ]]; then # If Iran server
        sudo iptables -A INPUT -s ${KHAREJ_VXLAN_IP%/*} -j ACCEPT # Accept from Kharej VXLAN internal IP
    elif [[ "$role_choice" == "2" ]]; then # If Kharej server
        sudo iptables -A INPUT -s ${IRAN_VXLAN_IP%/*} -j ACCEPT # Accept from Iran VXLAN internal IP
        # Add NAT (Masquerade) rule for traffic coming from VXLAN internal network to go to the internet
        sudo iptables -t nat -A POSTROUTING -o "$INTERFACE" -j MASQUERADE
        log_action "Enabled NAT on Kharej server."
    fi

    # Save iptables rules persistently
    sudo netfilter-persistent save > /dev/null 2>&1
    log_action "✅ iptables rules applied and saved persistently."


    # ---------------- CREATE SYSTEMD SERVICE ----------------
    echo -e "${YELLOW}Creating systemd service for VXLAN tunnel persistence...${NC}"
    log_action "Creating systemd service for VXLAN."

    cat <<EOF | sudo tee /usr/local/bin/vxlan_bridge.sh > /dev/null
#!/bin/bash
# Script to bring up VXLAN interface persistently and manage iptables
ip link del "$VXLAN_IF" 2>/dev/null || true # Ensure clean slate
ip link add "$VXLAN_IF" type vxlan id "$VNI" local \$(hostname -I | awk '{print \$1}' | head -n1) remote "$REMOTE_IP" dev "$INTERFACE" dstport "$DSTPORT" nolearning
ip addr add "$MY_VXLAN_IP" dev "$VXLAN_IF"
ip link set "$VXLAN_IF" up

# Re-add iptables rules on boot (ensuring persistence)
sudo iptables -A INPUT -p udp --dport "$DSTPORT" -j ACCEPT
sudo iptables -A INPUT -s "$REMOTE_IP" -j ACCEPT
if [[ "$role_choice" == "1" ]]; then # If Iran server
    sudo iptables -A INPUT -s ${KHAREJ_VXLAN_IP%/*} -j ACCEPT
elif [[ "$role_choice" == "2" ]]; then # If Kharej server
    sudo iptables -A INPUT -s ${IRAN_VXLAN_IP%/*} -j ACCEPT
    sudo iptables -t nat -A POSTROUTING -o "$INTERFACE" -j MASQUERADE
fi
sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1 # Ensure forwarding is enabled

# Persistent keepalive: ping remote every 30s in background to keep tunnel alive
( while true; do ping -c 1 "$REMOTE_IP" >/dev/null 2>&1; sleep 30; done ) &
EOF

    sudo chmod +x /usr/local/bin/vxlan_bridge.sh

    cat <<EOF | sudo tee /etc/systemd/system/vxlan-tunnel.service > /dev/null
[Unit]
Description=ExitTunnel VXLAN Tunnel Interface
After=network.target network-online.target

[Service]
ExecStart=/usr/local/bin/vxlan_bridge.sh
Type=oneshot
RemainAfterExit=yes
# Ensure ping process is killed on service stop
ExecStop=/bin/bash -c 'pkill -f "ping -c 1 $REMOTE_IP"' 
ExecStop=/sbin/ip link del $VXLAN_IF 2>/dev/null || true # Ensure interface is cleaned up on stop

[Install]
WantedBy=multi-user.target
EOF

    sudo chmod 644 /etc/systemd/system/vxlan-tunnel.service
    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload
    sudo systemctl enable vxlan-tunnel.service
    sudo systemctl start vxlan-tunnel.service
    log_action "✅ VXLAN tunnel service enabled and started."

    echo -e "\n${GREEN}[✓] VXLAN tunnel setup completed successfully.${NC}"

    echo -e "\n${YELLOW}Next Steps:${NC}"
    if [[ "$role_choice" == "1" ]]; then # Iran Server
        echo -e " - On your Iran Server (Public IP: $(get_public_ipv4)): HAProxy is set up for Auto-Dekomodor."
        echo -e " - Configure X-UI/Sanayi on this server."
        echo -e " - Create Inbounds (e.g., VLESS/TCP) on public ports that you configured for HAProxy (e.g., 443, 80)."
        echo -e " - For the Outbound of these Inbounds, configure them to use your Foreign Server's VXLAN internal IP: ${GREEN}${KHAREJ_VXLAN_IP%/*}${NC}"
        echo -e " - Example: VLESS/TCP Outbound: Server IP: ${GREEN}${KHAREJ_VXLAN_IP%/*}${NC}, Port: (Any port X-UI on Kharej listens on, e.g., 443 or 80)"
        echo -e " - Ensure your X-UI Inbound public ports (e.g., 443, 80) are open in your Iran Server's firewall."
        echo -e " - Your Exit IP will be your Iran Server's Public IP!"
    elif [[ "$role_choice" == "2" ]]; then # Kharej Server
        echo -e " - On your Kharej Server (Public IP: $(get_public_ipv4)): Install Sanayi/X-UI here."
        echo -e " - Create Inbounds (e.g., VLESS/TCP) listening on the VXLAN internal IP: ${GREEN}${KHAREJ_VXLAN_IP%/*}${NC}"
        echo -e " - Example: VLESS/TCP Inbound: Listen IP: ${GREEN}${KHAREJ_VXLAN_IP%/*}${NC}, Port: (e.g., 443 or 80)"
        echo -e " - Ensure your firewall on Kharej server allows traffic from Iran's VXLAN internal IP (${IRAN_VXLAN_IP%/*}) to reach ${KHAREJ_VXLAN_IP%/*}:${PUBLIC_PORT}."
        echo -e " - NAT (Masquerade) rules are automatically applied to allow internet access from VXLAN."
    fi
    echo -e "\n${MAGENTA}Remember to run this script on BOTH your Iran and Foreign servers!${NC}"
    press_enter_to_continue
}

# --- Tunnel Service Management Menu ---
function manage_exittunnel_services() {
    while true; do
        clear
        echo -e "${CYAN}----------------------------------------------------${NC}"
        echo -e "${YELLOW} ExitTunnel Service Management ${NC}"
        echo -e "${CYAN}----------------------------------------------------${NC}"
        echo -e "${GREEN}1. Start VXLAN Tunnel Service${NC}"
        echo -e "${RED}2. Stop VXLAN Tunnel Service${NC}"
        echo -e "${PURPLE}3. Restart VXLAN Tunnel Service${NC}"
        echo -e "${BLUE}4. Check VXLAN Tunnel Service Status & Logs${NC}"
        echo -e "${GREEN}5. Start HAProxy Service (Iran Only)${NC}"
        echo -e "${RED}6. Stop HAProxy Service (Iran Only)${NC}"
        echo -e "${PURPLE}7. Restart HAProxy Service (Iran Only)${NC}"
        echo -e "${BLUE}8. Check HAProxy Service Status & Logs (Iran Only)${NC}"
        echo -e "${WHITE}9. Back to Main Menu${NC}"
        echo -e "${CYAN}----------------------------------------------------${NC}"
        read -p "$(echo -e "${BLUE}Please enter your choice: ${NC}")" sub_choice

        case $sub_choice in
            1)
                echo -e "${YELLOW}Starting VXLAN tunnel service...${NC}"
                sudo systemctl start vxlan-tunnel.service
                if sudo systemctl is-active --quiet vxlan-tunnel.service; then
                    echo -e "${GREEN}VXLAN tunnel service started successfully.${NC}"
                else
                    echo -e "${RED}Failed to start VXLAN tunnel service. Check logs with 'sudo systemctl status vxlan-tunnel.service'.${NC}"
                fi
                press_enter_to_continue
                ;;
            2)
                echo -e "${YELLOW}Stopping VXLAN tunnel service...${NC}"
                sudo systemctl stop vxlan-tunnel.service
                if ! sudo systemctl is-active --quiet vxlan-tunnel.service; then
                    echo -e "${GREEN}VXLAN tunnel service stopped successfully.${NC}"
                else
                    echo -e "${RED}Failed to stop VXLAN tunnel service. Check logs with 'sudo systemctl status vxlan-tunnel.service'.${NC}"
                fi
                press_enter_to_continue
                ;;
            3)
                echo -e "${YELLOW}Restarting VXLAN tunnel service...${NC}"
                sudo systemctl restart vxlan-tunnel.service
                if sudo systemctl is-active --quiet vxlan-tunnel.service; then
                    echo -e "${GREEN}VXLAN tunnel service restarted successfully.${NC}"
                else
                    echo -e "${RED}Failed to restart VXLAN tunnel service. Check logs with 'sudo systemctl status vxlan-tunnel.service'.${NC}"
                fi
                press_enter_to_continue
                ;;
            4)
                echo -e "${YELLOW}Checking VXLAN tunnel service status...${NC}"
                sudo systemctl status vxlan-tunnel.service --no-pager
                echo -e "\n${YELLOW}Last 10 VXLAN tunnel logs:${NC}"
                journalctl -u vxlan-tunnel.service -n 10 --no-pager
                press_enter_to_continue
                ;;
            5)
                echo -e "${YELLOW}Starting HAProxy service...${NC}"
                sudo systemctl start haproxy
                if sudo systemctl is-active --quiet haproxy; then
                    echo -e "${GREEN}HAProxy service started successfully.${NC}"
                else
                    echo -e "${RED}Failed to start HAProxy service. Check logs with 'sudo systemctl status haproxy'.${NC}"
                fi
                press_enter_to_continue
                ;;
            6)
                echo -e "${YELLOW}Stopping HAProxy service...${NC}"
                sudo systemctl stop haproxy
                if ! sudo systemctl is-active --quiet haproxy; then
                    echo -e "${GREEN}HAProxy service stopped successfully.${NC}"
                else
                    echo -e "${RED}Failed to stop HAProxy service. Check logs with 'sudo systemctl status haproxy'.${NC}"
                fi
                press_enter_to_continue
                ;;
            7)
                echo -e "${YELLOW}Restarting HAProxy service...${NC}"
                sudo systemctl restart haproxy
                if sudo systemctl is-active --quiet haproxy; then
                    echo -e "${GREEN}HAProxy service restarted successfully.${NC}"
                else
                    echo -e "${RED}Failed to restart HAProxy service. Check logs with 'sudo systemctl status haproxy'.${NC}"
                fi
                press_enter_to_continue
                ;;
            8)
                echo -e "${YELLOW}Checking HAProxy service status...${NC}"
                sudo systemctl status haproxy --no-pager
                echo -e "\n${YELLOW}Last 10 HAProxy logs:${NC}"
                journalctl -u haproxy -n 10 --no-pager
                press_enter_to_continue
                ;;
            9)
                echo -e "${PURPLE}Returning to main menu...${NC}"
                return
                ;;
            *)
                echo -e "${RED}Invalid option. Please enter a number between 1 and 9.${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}


# --- Main script logic (loop for main menu) ---
function main_script_loop() {
    while true; do
        display_main_menu
        case $choice in
            1)
                install_new_tunnel # This function handles role selection and setup
                ;;
            2)
                manage_exittunnel_services
                ;;
            3)
                display_header # Refresh header for advanced tools menu
                echo -e "${CYAN}----------------------------------------------------${NC}"
                echo -e "${YELLOW} Advanced Tools ${NC}"
                echo -e "${CYAN}----------------------------------------------------${NC}"
                echo -e "${GREEN}1. Install BBR (Network Optimization)${NC}"
                echo -e "${BLUE}2. Install Cronjob (Auto-Restart Services)${NC}"
                echo -e "${WHITE}3. Back to Main Menu${NC}"
                echo -e "${CYAN}----------------------------------------------------${NC}"
                read -p "$(echo -e "${BLUE}Your choice: ${NC}")" advanced_choice
                case $advanced_choice in
                    1) install_bbr_script ;;
                    2) install_restart_cronjob ;;
                    3) ;; # Go back to main menu
                    *) echo -e "${RED}Invalid option. Try again.${NC}"; press_enter_to_continue ;;
                esac
                ;;
            4)
                read -p "$(echo -e "${RED}Are you sure you want to uninstall ALL ExitTunnel components? (y/N): ${NC}")" confirm_uninstall
                if [[ "$confirm_uninstall" =~ ^[yY]$ ]]; then
                    uninstall_all_exittunnel_components
                else
                    echo -e "${YELLOW}Uninstallation cancelled.${NC}"
                    press_enter_to_continue
                fi
                ;;
            5)
                echo -e "${PURPLE}Exiting ExitTunnel Manager. Goodbye!${NC}"
                log_action "Exiting script."
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option. Please enter a number between 1 and 5.${NC}"
                press_enter_to_continue
                ;;
        esac
    done
}

# --- Initial Setup for Persistent Command ---
function setup_persistent_command() {
    local SCRIPT_NAME=$(basename "$0") # Gets 'ExitTunnel.sh'
    # Ensure the script is copied and symlinked properly.
    # The check readlink -f "$0" ensures we get the absolute path of the currently executing script
    # regardless of how it was called (e.g., ./ExitTunnel.sh or symlink).
    if [ ! -f "$PERSISTENT_SCRIPT_PATH" ] || [ "$(readlink -f "$0")" != "$PERSISTENT_SCRIPT_PATH" ]; then
        echo -e "${YELLOW}Setting up persistent 'exittunnel' command...${NC}"
        log_action "Configuring persistent 'exittunnel' command."
        sudo cp "$0" "$PERSISTENT_SCRIPT_PATH" # Copy the current running script to a persistent location
        sudo chmod +x "$PERSISTENT_SCRIPT_PATH"
        sudo ln -sf "$PERSISTENT_SCRIPT_PATH" "$SYMLINK_PATH" # Create a symlink
        echo -e "${GREEN}✅ 'exittunnel' command is now set up. You can run the script by typing 'exittunnel' from anywhere.${NC}"
        press_enter_to_continue
        log_action "Persistent command setup complete."
    fi
}

# --- Start the script ---
# This block handles the very first execution and subsequent runs via 'exittunnel' command
if [[ "$(readlink -f "$0")" != "$PERSISTENT_SCRIPT_PATH" ]]; then
    setup_persistent_command
fi
main_script_loop # Start the main menu loop

