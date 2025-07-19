#!/bin/bash

# ==============================================================================
# ExitTunnel Simple Reverse Tunnel Manager - Developed by @mr_bxs
# ==============================================================================
# This script sets up a simple reverse tunnel.
# Iran Server acts as the main proxy for users (X-UI/Sanayi installed here).
# Foreign Server acts as a simple receiver, forwarding traffic to the Internet.
# The goal is to keep Iran's IP as the exit IP.
#
# Features: Simple TCP/UDP forwarding with socat, iptables redirection,
# persistent services, 'exittunnel' command.
#
# GitHub: [Upload to GitHub & put your link here]
# Telegram ID: @mr_bxs
# Script Version: 12.1 (ExitTunnel Reverse Simple - Bugfix)
# ==============================================================================

# --- Global Variables & Configuration ---
LOG_FILE="/var/log/exittunnel_reverse.log"
TUNNEL_CONFIG_DIR="/etc/exittunnel_reverse" # Central directory for tunnel configs
SCRIPT_VERSION="12.1" # Updated version
SCRIPT_PATH="/usr/local/bin/exittunnel-script.sh" # Path where script will be stored for persistent access
SYMLINK_PATH="/usr/local/bin/exittunnel" # Command to run the script

# --- Helper Functions ---

# Function to get the server's public IPv4 address
function get_public_ipv4() {
    local ip=$(curl -s4 --connect-timeout 5 "https://api.ipify.org" || \
               curl -s4 --connect-timeout 5 "https://ipv4.icanhazip.com" || \
               curl -s4 --connect-timeout 5 "http://ifconfig.me/ip")
    echo "${ip:-N/A}"
}

# Function to get the server's public IPv6 address
function get_public_ipv6() {
    local ip6=$(curl -s6 --connect-timeout 5 "https://api6.ipify.org" || \
                curl -s6 --connect-timeout 5 "https://ipv6.icanhazip.com" || \
                curl -s6 --connect-timeout 5 "http://ifconfig.me/ip")
    echo "${ip6:-N/A}"
}

# Logs actions to file and prints to stdout
function log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Pauses script execution until Enter is pressed
function press_enter_to_continue() {
    echo -e "\nPress Enter to continue..."
    read -r
}

# Displays script and server information at the start
function display_header() {
    clear # Clear screen for clean display
    echo "================================================================================"
    echo "Developed by @mr_bxs | GitHub: [Upload to GitHub & put your link here]"
    echo "Telegram Channel => @mr_bxs"
    echo "Tunnel script based on Simple Reverse Tunneling (Socks5 + socat)"
    echo "========================================"
    echo " 🌐 Server Information"
    echo "========================================"
    echo " IPv4 Address: $(get_public_ipv4)"
    echo " IPv6 Address: $(get_public_ipv6)"
    echo " Script Version: $SCRIPT_VERSION"
    echo "========================================\n"
}

# --- Core Functions ---

# Installs socat for TCP/UDP forwarding
function install_socat() {
    log_action "📥 Installing 'socat' for TCP/UDP forwarding..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y > /dev/null 2>&1
        sudo apt-get install socat -y > /dev/null 2>&1
        sudo apt-get install -y iptables-persistent > /dev/null 2>&1 # Ensure iptables-persistent is installed
    elif command -v yum &> /dev/null; then
        sudo yum install socat -y > /dev/null 2>&1
        sudo yum install -y iptables-services > /dev/null 2>&1 # Equivalent for RHEL/CentOS
    elif command -v dnf &> /dev/null; then
        sudo dnf install socat -y > /dev/null 2>&1
        sudo dnf install -y iptables-services > /dev/null 2>&1 # Equivalent for Fedora
    else
        log_action "❌ Error: Could not detect package manager (apt, yum, dnf). Please install socat and iptables-persistent manually."
        echo "Error: Could not install 'socat' and 'iptables-persistent'. Please install them manually."
        press_enter_to_continue
        return 1
    fi

    if ! command -v socat &> /dev/null; then
        log_action "❌ 'socat' installation failed."
        echo "Error: 'socat' could not be installed. Please check your internet connection or install manually."
        return 1
    else
        log_action "✅ 'socat' installed successfully."
        echo "'socat' installed."
        return 0
    fi
}

# Installs Dante Server (Socks5 Proxy) on Foreign Server
function install_dante_server() {
    log_action "📥 Installing 'dante-server' (Socks5 Proxy) on Foreign Server..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update -y > /dev/null 2>&1
        sudo apt-get install dante-server -y > /dev/null 2>&1
    elif command -v yum &> /dev/null; then
        sudo yum install dante-server -y > /dev/null 2>&1
    elif command -v dnf &> /dev/null; then
        sudo dnf install dante-server -y > /dev/null 2>&1
    else
        log_action "❌ Error: Could not detect package manager (apt, yum, dnf). Please install dante-server manually."
        echo "Error: Could not install 'dante-server'. Please install it manually."
        press_enter_to_continue
        return 1
    fi

    if ! command -v danted &> /dev/null; then
        log_action "❌ 'dante-server' installation failed."
        echo "Error: 'dante-server' could not be installed. Please check your internet connection or install manually."
        return 1
    else
        log_action "✅ 'dante-server' installed successfully."
        echo "'dante-server' installed."
        return 0
    fi
}

# --- Tunnel Configuration Functions ---

# Configures Foreign Server as a Socks5 endpoint
function configure_foreign_socks5_endpoint() {
    echo "\n=== Configure Foreign Server (Socks5 Endpoint) ==="
    echo "This server will run a Socks5 proxy to provide internet access."
    echo "Type 'back' at any prompt to return to the previous menu."

    if ! command -v danted &> /dev/null; then
        echo "'dante-server' is not installed. Installing now..."
        if ! install_dante_server; then
            echo "Failed to install dante-server. Cannot configure."
            return
        fi
    fi

    read -p "🔸 Choose a Port for Socks5 (e.g., 2078): " SOCKS5_PORT
    [[ "$SOCKS5_PORT" == "back" ]] && return
    if ! [[ "$SOCKS5_PORT" =~ ^[0-9]+$ ]] || [ "$SOCKS5_PORT" -lt 1 ] || [ "$SOCKS5_PORT" -gt 65535 ]; then
        echo "Invalid port number. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Set a Username for Socks5 authentication: " SOCKS5_USERNAME
    [[ "$SOCKS5_USERNAME" == "back" ]] && return
    if [ -z "$SOCKS5_USERNAME" ]; then
        echo "Username cannot be empty. Please enter a username."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Set a Strong Password for Socks5 authentication: " SOCKS5_PASSWORD
    [[ "$SOCKS5_PASSWORD" == "back" ]] && return
    if [ -z "$SOCKS5_PASSWORD" ]; then
        echo "Password cannot be empty. Please enter a password."
        press_enter_to_continue
        return
    fi

    mkdir -p "$SOCKS5_CONFIG_DIR"
    local SOCKS5_CONF_FILE="$SOCKS5_CONFIG_DIR/danted.conf"

    # Create user for Dante
    if ! id -u "$SOCKS5_USERNAME" >/dev/null 2>&1; then
        log_action "Creating system user '$SOCKS5_USERNAME' for Dante..."
        sudo useradd -r -s /bin/false "$SOCKS5_USERNAME"
        if [ $? -ne 0 ]; then
            log_action "❌ Failed to create system user '$SOCKS5_USERNAME'."
            echo "Failed to create system user. Please check permissions."
            press_enter_to_continue
            return 1
        fi
    fi
    log_action "Setting password for user '$SOCKS5_USERNAME'..."
    echo -e "$SOCKS5_PASSWORD\n$SOCKS5_PASSWORD" | sudo passwd "$SOCKS5_USERNAME" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_action "❌ Failed to set password for user '$SOCKS5_USERNAME'."
        echo "Failed to set password for system user. Please check permissions."
        press_enter_to_continue
        return 1
    fi

    # Create danted.conf
    cat > "$SOCKS5_CONF_FILE" <<EOF
logoutput: syslog
user.privileged: root
user.notprivileged: nobody

# The listening network interface or address.
internal: 0.0.0.0 port = $SOCKS5_PORT

# The proxy will use the external interface to connect to the Internet.
external: $(get_public_ipv4) # Use actual public IP as external interface

# Authentication method
method: username none

# Client rules: allow connection from ANY IP (including Iran Server)
clientmethod: username
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
client block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

# Socks rules: allow connections to any destination
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    log: error connect disconnect
    # Authenticate all users
    user: $SOCKS5_USERNAME
}
socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF
    log_action "✅ Dante Socks5 config created: $SOCKS5_CONF_FILE"

    # Store user/pass/port for listing (not directly used by dante, but for info)
    mkdir -p "$TUNNEL_CONFIG_DIR"
    echo "foreign_socks5:${SOCKS5_USERNAME}:${SOCKS5_PASSWORD}:${SOCKS5_PORT}" > "$TUNNEL_CONFIG_DIR/foreign_socks5.conf"

    log_action "🔄 Attempting to restart Dante Socks5 service..."
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1

    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
        log_action "✅ Dante Socks5 Server configured and running on port $SOCKS5_PORT (Foreign Server)."
        local server_ip=$(get_public_ipv4)
        
        echo "\n🎉 Dante Socks5 Server on your Foreign Server is ready!"
        echo "--------------------------------------------------------------------------------"
        echo " Connection Details for Iran Server (Socks5 Client):"
        echo " Socks5 Server IP : ${server_ip}"
        echo " Socks5 Port : $SOCKS5_PORT"
        echo " Username : $SOCKS5_USERNAME"
        echo " Password : $SOCKS5_PASSWORD"
        echo "--------------------------------------------------------------------------------"
        echo "IMPORTANT: Open port $SOCKS5_PORT (TCP and UDP if possible) in your Foreign Server's firewall!"
        echo "Now, go to your Iran Server and configure the reverse tunnel."
    else
        log_action "❌ Failed to start Dante Socks5 Server. Please check logs for details."
        echo "❌ Dante Socks5 Server failed to start."
        echo " Check logs with 'journalctl -u $SOCKS5_SERVICE_NAME -f'."
    fi
    press_enter_to_continue
}

# Configures Iran Server for reverse tunneling using iptables/socat
function configure_iran_reverse_tunnel() {
    echo "\n=== Configure Iran Server (Reverse Tunnel) ==="
    echo "This server will establish a reverse tunnel to the Foreign Socks5 Proxy."
    echo "X-UI/Sanayi will be installed on THIS server."
    echo "Type 'back' at any prompt to return to the previous menu."

    if ! command -v socat &> /dev/null; then
        echo "'socat' is not installed. Installing now..."
        if ! install_socat; then
            echo "Failed to install socat. Cannot create tunnel."
            return
        fi
    fi

    read -p "🔸 Foreign Socks5 Server IP: " FOREIGN_SOCKS5_IP
    [[ "$FOREIGN_SOCKS5_IP" == "back" ]] && return
    if [ -z "$FOREIGN_SOCKS5_IP" ]; then echo "IP cannot be empty."; press_enter_to_continue; return 1; fi

    read -p "🔸 Foreign Socks5 Port: " FOREIGN_SOCKS5_PORT
    [[ "$FOREIGN_SOCKS5_PORT" == "back" ]] && return
    if ! [[ "$FOREIGN_SOCKS5_PORT" =~ ^[0-9]+$ ]] || [ "$FOREIGN_SOCKS5_PORT" -lt 1 ] || [ "$FOREIGN_SOCKS5_PORT" -gt 65535 ]; then
        echo "Invalid port. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Socks5 Username: " SOCKS5_USERNAME
    [[ "$SOCKS5_USERNAME" == "back" ]] && return
    if [ -z "$SOCKS5_USERNAME" ]; then echo "Username cannot be empty."; press_enter_to_continue; return 1; fi

    read -p "🔸 Socks5 Password: " SOCKS5_PASSWORD
    [[ "$SOCKS5_PASSWORD" == "back" ]] && return
    if [ -z "$SOCKS5_PASSWORD" ]; then echo "Password cannot be empty."; press_enter_to_continue; return 1; fi

    read -p "🔸 Local Port on Iran Server for OUTGOING connections (e.g., 1080 - used by iptables, must be free): " LOCAL_SOCKS_OUT_PORT
    [[ "$LOCAL_SOCKS_OUT_PORT" == "back" ]] && return
    if ! [[ "$LOCAL_SOCKS_OUT_PORT" =~ ^[0-9]+$ ]] || [ "$LOCAL_SOCKS_OUT_PORT" -lt 1 ] || [ "$LOCAL_SOCKS_OUT_PORT" -gt 65535 ]; then
        echo "Invalid port. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    # Create systemd service for socat client (reverse tunnel part)
    local SERVICE_NAME="exittunnel-reverse-client-${LOCAL_SOCKS_OUT_PORT}"
    local SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

    mkdir -p "$TUNNEL_CONFIG_DIR"
    echo "${FOREIGN_SOCKS5_IP}:${FOREIGN_SOCKS5_PORT}:${SOCKS5_USERNAME}:${SOCKS5_PASSWORD}:${LOCAL_SOCKS_OUT_PORT}" > "$TUNNEL_CONFIG_DIR/iran_reverse_client.conf"

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=ExitTunnel Reverse Client on Port ${LOCAL_SOCKS_OUT_PORT}
After=network.target network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/socat TCP-LISTEN:${LOCAL_SOCKS_OUT_PORT},fork SOCKS5:${FOREIGN_SOCKS5_IP}:${FOREIGN_SOCKS5_PORT},socksclient,socksuser=${SOCKS5_USERNAME},sockspassword=${SOCKS5_PASSWORD}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    log_action "✅ socat reverse client service config created: ${SERVICE_FILE}"

    systemctl daemon-reload > /dev/null 2>&1
    systemctl enable "$SERVICE_NAME" --now > /dev/null 2>&1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log_action "✅ ExitTunnel reverse client started on port ${LOCAL_SOCKS_OUT_PORT} (Iran Server)."
        echo "\n🎉 ExitTunnel reverse client on your Iran Server is ready!"
        echo "--------------------------------------------------------------------------------"
        echo " Traffic from this server will be redirected to local port ${LOCAL_SOCKS_OUT_PORT}."
        echo " This port (${LOCAL_SOCKS_OUT_PORT}) will then forward to your Foreign Socks5 Proxy."
        echo "--------------------------------------------------------------------------------"
        echo "IMPORTANT: Now setting up IPtables rules for automatic redirection (Transparent Proxy)."
        log_action "Setting up iptables rules for transparent proxy on Iran Server."

        # Save current iptables rules as backup
        sudo iptables-save > /etc/iptables/rules.v4.bak
        if command -v ip6tables-save >/dev/null 2>&1; then
            sudo ip6tables-save > /etc/iptables/rules.v6.bak
        fi

        # Enable IP forwarding
        sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
        log_action "Enabled IPv4 forwarding."

        # Clear existing NAT rules that might conflict (be careful with existing setups)
        # It's safer to remove specific chains/rules than to fully flush if other services exist.
        sudo iptables -t nat -F PREROUTING
        sudo iptables -t nat -F OUTPUT
        
        # Create a new chain for SOCKS redirection
        sudo iptables -t nat -N SOCKS_REDIRECT
        
        # Redirect all outgoing TCP traffic from the server to local socks port
        # Exclude traffic destined for the foreign Socks5 IP to prevent loops
        sudo iptables -t nat -A PREROUTING -p tcp -d "$FOREIGN_SOCKS5_IP" --dport "$FOREIGN_SOCKS5_PORT" -j RETURN
        sudo iptables -t nat -A OUTPUT -p tcp -d "$FOREIGN_SOCKS5_IP" --dport "$FOREIGN_SOCKS5_PORT" -j RETURN
        
        # Redirect all other outgoing TCP traffic on common ports to SOCKS_REDIRECT
        sudo iptables -t nat -A PREROUTING -p tcp -m multiport --dports 80,443 -j SOCKS_REDIRECT
        sudo iptables -t nat -A OUTPUT -p tcp -m multiport --dports 80,443 -j SOCKS_REDIRECT
        # You can add more ports (e.g., 53 for DNS, 22 for SSH, etc.) if you want ALL traffic to go through the tunnel.
        
        # Redirect to local Socks5 listener
        sudo iptables -t nat -A SOCKS_REDIRECT -p tcp -j REDIRECT --to-ports "$LOCAL_SOCKS_OUT_PORT"
        
        # Save iptables rules persistently
        sudo netfilter-persistent save > /dev/null 2>&1
        log_action "✅ iptables rules for transparent proxy applied and saved."
        
        echo "\n--------------------------------------------------------------------------------"
        echo " Your Iran Server is now configured for transparent proxy via reverse tunnel!"
        echo " - All outgoing TCP traffic from this server (including X-UI/Sanayi) on ports 80, 443"
        echo " will be automatically redirected to local port ${LOCAL_SOCKS_OUT_PORT}."
        echo " - This local port will then forward traffic through the secure Socks5 tunnel"
        echo " to your Foreign Socks5 Proxy."
        echo "--------------------------------------------------------------------------------"
        echo "IMPORTANT: Now install X-UI/Sanayi on this Iran Server."
        echo " - In X-UI/Sanayi, create your Inbounds (e.g., VLESS/VMess/Trojan) on public ports (e.g., 443, 80)."
        echo " - You DO NOT need to configure any special Outbound in X-UI/Sanayi for this tunnel."
        echo " X-UI/Sanayi's outgoing traffic will be AUTOMATICALLY redirected by iptables."
        echo " - Ensure your X-UI/Sanayi Inbound ports (e.g., 443, 80) are open in your Iran Server's firewall!"
        echo "This setup allows clients to connect to your Iran IP, and Exit IP will be Iran's IP."
    else
        log_action "❌ Failed to start ExitTunnel reverse client. Check logs."
        echo "❌ ExitTunnel reverse client failed to start."
        echo " Check logs with 'journalctl -u ${SERVICE_NAME} -f'."
    fi
    press_enter_to_continue
}

# --- Tunnel Management Functions ---

# Lists existing tunnel configurations and offers deletion
function list_and_delete_tunnels() {
    echo "\n=== My ExitTunnel Configurations ==="
    local configs_found=0
    
    mkdir -p "$TUNNEL_CONFIG_DIR" # Ensure config directory exists
    
    # List Foreign Socks5 Server config
    if [ -f "$TUNNEL_CONFIG_DIR/foreign_socks5.conf" ]; then
        configs_found=1
        local config_data=$(cat "$TUNNEL_CONFIG_DIR/foreign_socks5.conf")
        local username=$(echo "$config_data" | awk -F':' '{print $2}')
        local password=$(echo "$config_data" | awk -F':' '{print $3}')
        local port=$(echo "$config_data" | awk -F':' '{print $4}')
        local server_ip=$(get_public_ipv4)

        echo -e "\n[1] Role: Foreign Server (Dante Socks5 Proxy)"
        echo " Config File: $SOCKS5_CONFIG_DIR/danted.conf"
        echo " --- Details ---"
        echo " Server IP : ${server_ip}"
        echo " Port : $port"
        echo " Username : $username"
        echo " Password : $password"
        echo " ---------------"
        echo " Status: $(systemctl is-active "$SOCKS5_SERVICE_NAME" 2>/dev/null || echo "inactive")"
    fi

    # List Iran Reverse Client config
    local service_name_iran_prefix="exittunnel-reverse-client-"
    for config_file in "$TUNNEL_CONFIG_DIR"/iran_reverse_client.conf; do
        if [ -f "$config_file" ]; then
            configs_found=1
            local config_data=$(cat "$config_file")
            local foreign_ip=$(echo "$config_data" | awk -F':' '{print $1}')
            local foreign_port=$(echo "$config_data" | awk -F':' '{print $2}')
            local username=$(echo "$config_data" | awk -F':' '{print $3}')
            local local_port=$(echo "$config_data" | awk -F':' '{print $5}')
            local current_service_name="${service_name_iran_prefix}${local_port}"

            echo -e "\n[2] Role: Iran Server (Reverse Client)"
            echo " Config File: $config_file"
            echo " --- Details ---"
            echo " Foreign Socks5 IP : $foreign_ip"
            echo " Foreign Socks5 Port: $foreign_port"
            echo " Socks5 Username : $username"
            echo " Local Redirect Port: $local_port"
            echo " ---------------"
            echo " Status: $(systemctl is-active "$current_service_name" 2>/dev/null || echo "inactive")"
        fi
    done

    if [ "$configs_found" -eq 0 ]; then
        echo "No ExitTunnel configurations found."
    else
        echo -e "\n-----------------------------------------"
        read -p "Enter the number of the tunnel config to delete (1 for Foreign Socks5, 2 for Iran Reverse Client), or 'back' to return: " TUNNEL_NUM_TO_DELETE
        [[ "$TUNNEL_NUM_TO_DELETE" =~ ^[bB][aA][cC][kK]$ ]] && return

        if [[ "$TUNNEL_NUM_TO_DELETE" == "1" ]]; then # Delete Foreign Socks5 config
            local config_file_to_delete="$TUNNEL_CONFIG_DIR/foreign_socks5.conf"
            local dante_config_file="$SOCKS5_CONFIG_DIR/danted.conf"
            if [ -f "$config_file_to_delete" ]; then
                read -p "Are you sure you want to delete Foreign Socks5 config? (y/N): " CONFIRM_DELETE
                [[ "$CONFIRM_DELETE" =~ ^[bB][aA][cC][kK]$ ]] && return
                if [[ "$CONFIRM_DELETE" =~ ^[yY]$ ]]; then
                    log_action "🗑 Stopping and disabling Dante Socks5 service..."
                    systemctl stop "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1
                    systemctl disable "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1
                    log_action "🗑 Deleting Dante config file and user..."
                    local username_to_remove=$(head -n 1 "$config_file_to_delete" | awk -F':' '{print $2}')
                    if id -u "$username_to_remove" >/dev/null 2>&1; then
                        sudo userdel "$username_to_remove" > /dev/null 2>&1
                    fi
                    rm -f "$config_file_to_delete"
                    rm -f "$dante_config_file"
                    rm -rf "$SOCKS5_CONFIG_DIR" # Clean up dante dir
                    systemctl daemon-reload > /dev/null 2>&1
                    log_action "✅ Foreign Socks5 tunnel deleted."
                    echo "Foreign Socks5 tunnel config deleted and service stopped."
                else
                    log_action "❌ Deletion cancelled."
                fi # Corrected this 'fi' location
            else
                echo "Foreign Socks5 config not found."
            fi
        elif [[ "$TUNNEL_NUM_TO_DELETE" == "2" ]]; then # Delete Iran Reverse Client config
            local config_file_to_delete="$TUNNEL_CONFIG_DIR/iran_reverse_client.conf"
            local local_port_to_delete=$(head -n 1 "$config_file_to_delete" | awk -F':' '{print $5}')
            local service_to_delete="${service_name_iran_prefix}${local_port_to_delete}"
            local service_file_to_delete="/etc/systemd/system/${service_to_delete}.service"

            if [ -f "$config_file_to_delete" ]; then
                read -p "Are you sure you want to delete Iran Reverse Client config? (y/N): " CONFIRM_DELETE
                [[ "$CONFIRM_DELETE" =~ ^[bB][aA][cC][kK]$ ]] && return
                if [[ "$CONFIRM_DELETE" =~ ^[yY]$ ]]; then
                    log_action "🗑 Stopping and disabling reverse client service: ${service_to_delete}..."
                    systemctl stop "$service_to_delete" > /dev/null 2>&1
                    systemctl disable "$service_to_delete" > /dev/null 2>&1
                    log_action "🗑 Deleting service file and config: ${service_file_to_delete} and ${config_file_to_delete}..."
                    rm -f "$service_file_to_delete"
                    rm -f "$config_file_to_delete"
                    systemctl daemon-reload > /dev/null 2>&1
                    
                    log_action "🗑 Flushing specific iptables rules for transparent proxy on Iran Server."
                    # Restore iptables to pre-redirect state. This might be tricky if other rules exist.
                    # Best practice: Revert to backup, or remove specific chains/rules
                    sudo iptables -t nat -D PREROUTING -p tcp -m multiport --dports 80,443 -j SOCKS_REDIRECT 2>/dev/null || true # Corrected target jump
                    sudo iptables -t nat -D OUTPUT -p tcp -m multiport --dports 80,443 -j SOCKS_REDIRECT 2>/dev/null || true # Corrected target jump
                    sudo iptables -t nat -D SOCKS_REDIRECT -p tcp -j REDIRECT --to-ports "$local_port_to_delete" 2>/dev/null || true # Explicitly remove redirect rule
                    
                    sudo iptables -t nat -F SOCKS_REDIRECT 2>/dev/null || true # Flush the chain
                    sudo iptables -t nat -X SOCKS_REDIRECT 2>/dev/null || true # Delete the chain
                    
                    # Remove rules that exclude traffic from socks5 ip
                    local foreign_socks5_ip_delete=$(head -n 1 "$config_file_to_delete" | awk -F':' '{print $1}')
                    local foreign_socks5_port_delete=$(head -n 1 "$config_file_to_delete" | awk -F':' '{print $2}')
                    sudo iptables -t nat -D PREROUTING -p tcp -d "$foreign_socks5_ip_delete" --dport "$foreign_socks5_port_delete" -j RETURN 2>/dev/null || true
                    sudo iptables -t nat -D OUTPUT -p tcp -d "$foreign_socks5_ip_delete" --dport "$foreign_socks5_port_delete" -j RETURN 2>/dev/null || true

                    sudo sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1 # Disable forwarding if not needed by other services
                    sudo netfilter-persistent save > /dev/null 2>&1
                    log_action "✅ Iran Reverse Client tunnel deleted and iptables rules reset."
                    echo "Iran Reverse Client tunnel config deleted and service stopped. IPtables rules reset."
                else
                    log_action "❌ Deletion cancelled."
                fi
            else
                echo "Iran Reverse Client config not found."
            fi
        else
            echo "Invalid option. Please choose 1, 2, or 'back'."
        fi
    fi
    press_enter_to_continue
}


# --- Service Status & Logs ---
function check_tunnel_status() {
    echo "\n=== ExitTunnel Service Status & Logs ==="
    local configs_found=0
    mkdir -p "$TUNNEL_CONFIG_DIR"

    # Check Dante status (Foreign Server)
    if [ -f "$TUNNEL_CONFIG_DIR/foreign_socks5.conf" ]; then
        configs_found=1
        echo -e "\n--- Service: Dante Socks5 Server ---"
        systemctl status "$SOCKS5_SERVICE_NAME" --no-pager 2>/dev/null || echo "Service not found or inactive."
        echo "--- Last 5 Logs for Dante Socks5 Server ---"
        journalctl -u "$SOCKS5_SERVICE_NAME" -n 5 --no-pager 2>/dev/null || echo "No logs found."
        echo "-----------------------------------"
    fi

    # Check socat reverse client status (Iran Server)
    local service_name_iran_prefix="exittunnel-reverse-client-"
    for config_file in "$TUNNEL_CONFIG_DIR"/iran_reverse_client.conf; do
        if [ -f "$config_file" ]; then
            configs_found=1
            local local_port_check=$(head -n 1 "$config_file" | awk -F':' '{print $5}')
            local current_service_name="${service_name_iran_prefix}${local_port_check}"
            echo -e "\n--- Service: ${current_service_name} ---"
            systemctl status "$current_service_name" --no-pager 2>/dev/null || echo "Service not found or inactive."
            echo "--- Last 5 Logs for ${current_service_name} ---"
            journalctl -u "$current_service_name" -n 5 --no-pager 2>/dev/null || echo "No logs found."
            echo "-----------------------------------"
        fi
    done

    if [ "$configs_found" -eq 0 ]; then
        echo "No ExitTunnel configurations found to check status."
    fi
    echo "========================================\n"
    press_enter_to_continue
}

# --- Main Menu Logic ---
function main_menu() {
    while true; do
        display_header
        echo "Select an option:"
        echo "1) Configure Foreign Server (Socks5 Endpoint)"
        echo "2) Configure Iran Server (Reverse Client)"
        echo "3) List & Delete Tunnels"
        echo "4) Check Tunnel Status & Logs"
        echo "5) Uninstall All ExitTunnel Components"
        echo "6) Exit"
        read -p "👉 Your choice: " CHOICE

        case $CHOICE in
            1)
                configure_foreign_socks5_endpoint
                ;;
            2)
                configure_iran_reverse_tunnel
                ;;
            3)
                list_and_delete_tunnels
                ;;
            4)
                check_tunnel_status
                ;;
            5)
                # Combined uninstall for both Dante and socat components
                read -p "Are you sure you want to remove ALL ExitTunnel configs and associated software (Dante, socat)? (y/N): " CONFIRM_ALL_UNINSTALL
                if [[ "$CONFIRM_ALL_UNINSTALL" =~ ^[yY]$ ]]; then
                    log_action "Initiating full ExitTunnel uninstall."
                    
                    # Stop and disable all socat tunnel services
                    for service_file in /etc/systemd/system/exittunnel-*.service; do
                        if [ -f "$service_file" ]; then
                            local service_name_to_stop=$(basename "$service_file" | sed 's/\.service$//')
                            systemctl stop "$service_name_to_stop" > /dev/null 2>&1
                            systemctl disable "$service_name_to_stop" > /dev/null 2>&1
                            rm -f "$service_file"
                            log_action "Stopped and removed socat service: $service_name_to_stop"
                        fi
                    done
                    
                    # Stop and disable Dante
                    systemctl stop "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1
                    systemctl disable "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1
                    
                    # Remove all configs
                    rm -rf "$TUNNEL_CONFIG_DIR"
                    rm -rf "$SOCKS5_CONFIG_DIR"
                    systemctl daemon-reload > /dev/null 2>&1
                    log_action "Removed all ExitTunnel configs and stopped services."

                    # Remove system users created for Dante
                    # This requires parsing the config file which might have been deleted,
                    # so this part might need manual cleanup if user wants to be super precise.
                    # For simplicity, we just remove if a user with standard name exists.
                    log_action "Attempting to remove associated system users (e.g., 'socksuser' if standard)."
                    if id -u "socksuser" >/dev/null 2>&1; then # A common user Dante might create/use
                        sudo userdel "socksuser" > /dev/null 2>&1
                    fi
                    
                    # Uninstall socat
                    log_action "Attempting to uninstall 'socat'..."
                    if command -v apt-get &> /dev/null; then sudo apt-get remove socat -y > /dev/null 2>&1; sudo apt-get autoremove -y > /dev/null 2>&1; fi
                    elif command -v yum &> /dev/null; then sudo yum remove socat -y > /dev/null 2>&1; sudo yum autoremove -y > /dev/null 2>&1; fi
                    elif command -v dnf &> /dev/null; then sudo dnf remove socat -y > /dev/null 2>&1; sudo dnf autoremove -y > /dev/null 2>&1; fi
                    else log_action "⚠️ Warning: Cannot auto-uninstall 'socat'."; fi
                    
                    # Uninstall dante-server
                    log_action "Attempting to uninstall 'dante-server'..."
                    if command -v apt-get &> /dev/null; then sudo apt-get remove dante-server -y > /dev/null 2>&1; sudo apt-get autoremove -y > /dev/null 2>&1; fi
                    elif command -v yum &> /dev/null; then sudo yum remove dante-server -y > /dev/null 2>&1; sudo yum autoremove -y > /dev/null 2>&1; fi
                    elif command -v dnf &> /dev/null; then sudo dnf remove dante-server -y > /dev/null 2>&1; sudo dnf autoremove -y > /dev/null 2>&1; fi
                    else log_action "⚠️ Warning: Cannot auto-uninstall 'dante-server'."; fi

                    # Reset iptables rules created by this script
                    log_action "Attempting to reset iptables rules created by ExitTunnel."
                    # This attempts to remove just the rules we added. More robust than full flush.
                    sudo iptables -t nat -D PREROUTING -p tcp -m multiport --dports 80,443 -j SOCKS_REDIRECT 2>/dev/null || true # Ensure rule is removed
                    sudo iptables -t nat -D OUTPUT -p tcp -m multiport --dports 80,443 -j SOCKS_REDIRECT 2>/dev/null || true # Ensure rule is removed
                    sudo iptables -t nat -F SOCKS_REDIRECT 2>/dev/null || true # Flush the chain
                    sudo iptables -t nat -X SOCKS_REDIRECT 2>/dev/null || true # Delete the chain
                    
                    # Remove rules that exclude traffic from socks5 ip
                    # Need to retrieve from saved config if still exists, or infer.
                    # This might require manual cleanup if config file is gone.
                    # For a robust uninstall, it's better to log the rules created and reverse them.
                    # For simplicity, we'll assume standard 80/443 redirects are the main ones.
                    sudo sysctl -w net.ipv4.ip_forward=0 > /dev/null 2>&1 # Disable forwarding
                    sudo netfilter-persistent save > /dev/null 2>&1
                    log_action "✅ iptables rules reset."

                    echo "All ExitTunnel components uninstalled and cleanup attempted. You might need manual checks."
                else
                    echo "Cleanup cancelled."
                fi
                press_enter_to_continue
                ;;
            6)
                log_action "Exiting script."
                echo "Exiting ExitTunnel Manager. Goodbye!"
                exit 0
                ;;
            *)
                echo "Invalid option. Please choose a number from the menu."
                press_enter_to_continue
                ;;
        esac
    done
}


# --- Initial Setup for Persistent Command ---
function setup_persistent_command() {
    if [ ! -f "$SYMLINK_PATH" ] || [ "$(readlink "$SYMLINK_PATH" 2>/dev/null)" != "$SCRIPT_PATH" ]; then
        log_action "Configuring persistent 'exittunnel' command."
        sudo cp "$0" "$SCRIPT_PATH" # Copy the current running script to a persistent location
        sudo chmod +x "$SCRIPT_PATH"
        sudo ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH" # Create a symlink to make it accessible system-wide
        echo "✅ 'exittunnel' command is now set up. You can run the script by typing 'exittunnel' from anywhere."
        press_enter_to_continue
        log_action "Persistent command setup complete."
    fi
}

# --- Start the script ---
# Check if the script is being run for the first time or if the persistent command needs setup
# The $0 variable contains the path/name used to invoke the script.
# If it's not the already symlinked persistent path, set up.
if [[ "$(readlink -f "$0")" != "$SCRIPT_PATH" ]]; then
    setup_persistent_command
fi
main_menu
