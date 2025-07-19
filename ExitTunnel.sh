#!/bin/bash

# ==============================================================================
# ExitTunnel Ultra Simple Manager - Developed by @mr_bxs
# ==============================================================================
# This script sets up a simple Hysteria tunnel.
# It configures one server as Hysteria Server (Iran side, for X-UI/Sanayi)
# and another as Hysteria Client (Foreign side, connected by Iran Server).
#
# GitHub: [Upload to GitHub & put your link here]
# Telegram ID: @mr_bxs
# Script Version: 6.0 (ExitTunnel Ultra Simple)
# ==============================================================================

# --- Global Variables & Configuration ---
LOG_FILE="/var/log/exittunnel_simple.log"
HYSTERIA_CONFIG_DIR="/etc/hysteria" # Central directory for Hysteria configs
HYSTERIA_SERVICE_NAME="hysteria-server" # Common service name for Hysteria 2.x

# --- Helper Functions ---

# Function to get the server's public IPv4 address
function get_public_ipv4() {
    local ip=$(dig @resolver4.opendns.com myip.opendns.com +short -4 || \
               curl -s4 --connect-timeout 5 "https://api.ipify.org" || \
               curl -s4 --connect-timeout 5 "https://ipv4.icanhazip.com")
    echo "${ip:-N/A}"
}

# Function to get the server's public IPv6 address
function get_public_ipv6() {
    local ip6=$(dig @resolver4.opendns.com myip.opendns.com +short -6 || \
                curl -s6 --connect-timeout 5 "https://api6.ipify.org" || \
                curl -s6 --connect-timeout 5 "https://ipv6.icanhazip.com")
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
    echo "Tunnel script based on Hysteria 2 (Ultra Simple)"
    echo "========================================"
    echo "     🌐 Server Information"
    echo "========================================"
    echo "  IPv4 Address: $(get_public_ipv4)"
    echo "  IPv6 Address: $(get_public_ipv6)"
    echo "  Script Version: $SCRIPT_VERSION"
    echo "========================================\n"
}

# --- Installation & Uninstallation ---

# Installs Hysteria 2.x
function install_hysteria() {
    log_action "📥 Attempting to install Hysteria (v2.x compatible) on this server..."
    if ! command -v curl &> /dev/null; then
        log_action "❌ Error: 'curl' is not installed. Please install it first (e.g., sudo apt install curl or sudo yum install curl)."
        press_enter_to_continue
        return 1
    fi
    if ! command -v dig &> /dev/null; then
        log_action "⚠️ Warning: 'dig' is not installed. IP detection might be less reliable. Install dnsutils (e.g., sudo apt install dnsutils or sudo yum install bind-utils)."
    fi

    bash <(curl -fsSL https://get.hy2.sh/)
    if [ $? -eq 0 ]; then
        log_action "✅ Hysteria installed successfully."
        echo "Hysteria installation completed."
    else
        log_action "❌ Hysteria installation failed. Please check your internet connection and try again."
        echo "Hysteria installation failed."
    fi
    press_enter_to_continue
}

# Uninstalls Hysteria and cleans up all related files
function uninstall_hysteria_and_cleanup() {
    echo "\n=== Uninstall Hysteria and Cleanup ==="
    read -p "Are you absolutely sure you want to uninstall Hysteria and remove ALL related files/configs? (y/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[bB][aA][cC][kK]$ ]] && return

    if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
        log_action "🗑 Attempting to uninstall Hysteria and clean up..."
        echo "Stopping and disabling Hysteria service..."
        systemctl stop "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl stop hy2 > /dev/null 2>&1
        systemctl disable "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl disable hy2 > /dev/null 2>&1

        echo "Removing Hysteria binary, service files, and config directory..."
        rm -f /usr/local/bin/hy2
        rm -f /usr/local/bin/hysteria
        rm -f "/etc/systemd/system/$HYSTERIA_SERVICE_NAME.service"
        rm -f "/etc/systemd/system/hy2.service"
        rm -rf "$HYSTERIA_CONFIG_DIR"
        systemctl daemon-reload > /dev/null 2>&1
        log_action "✅ Hysteria uninstalled and cleaned up successfully."
        echo "Hysteria has been completely uninstalled and related files removed."
    else
        log_action "❌ Uninstallation cancelled by user."
        echo "Uninstallation cancelled."
    fi
    press_enter_to_continue
}

# --- Tunnel Configuration Functions ---

# Configures Hysteria Client (on Foreign Server)
function configure_foreign_client() {
    echo "\n=== Configure Foreign Server (Hysteria Client) ==="
    echo "This server will act as Hysteria Client, receiving connections from Iran Server (Hysteria Server)."
    echo "Type 'back' at any prompt to return to the previous menu."

    if ! command -v hy2 &> /dev/null && ! command -v hysteria &> /dev/null; then
        echo "Hysteria is not installed. Please install it first (Option 1 in main menu)."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Choose a Port for Hysteria Client to LISTEN on (e.g., 20000 - Iran Server will connect to this port): " HY_PORT
    [[ "$HY_PORT" == "back" ]] && return
    if ! [[ "$HY_PORT" =~ ^[0-9]+$ ]] || [ "$HY_PORT" -lt 1 ] || [ "$HY_PORT" -gt 65535 ]; then
        echo "Invalid port number. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Set a Strong Password for the Tunnel: " HY_PASSWORD
    [[ "$HY_PASSWORD" == "back" ]] && return
    if [ -z "$HY_PASSWORD" ]; then
        echo "Password cannot be empty. Please enter a password."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Tunnel Protocol (udp or tcp, default: udp): " HY_PROTOCOL
    HY_PROTOCOL=${HY_PROTOCOL:-udp} # Set default to udp
    [[ "$HY_PROTOCOL" == "back" ]] && return
    if [[ "$HY_PROTOCOL" != "udp" && "$HY_PROTOCOL" != "tcp" ]]; then
        echo "Invalid protocol. Please choose 'udp' or 'tcp'."
        press_enter_to_continue
        return
    fi

    mkdir -p "$HYSTERIA_CONFIG_DIR"
    HY_CONFIG_FILE="$HYSTERIA_CONFIG_DIR/foreign_client_config.yaml"

    cat > "$HY_CONFIG_FILE" <<EOF
# Hysteria Client config for Foreign Server
listen: 0.0.0.0:$HY_PORT
protocol: $HY_PROTOCOL
password: ["$HY_PASSWORD"]
# No TLS needed for simple client setup (assuming Iran Server handles it)
# No Obfuscation/SNI for simple setup
EOF

    log_action "✅ Hysteria Client config created: $HY_CONFIG_FILE"
    
    log_action "🔄 Attempting to restart Hysteria service (Client Mode) on Foreign Server..."
    # Hysteria 2.x can act as client or server based on config.
    # It will use this config if it's the only one found.
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl restart hy2 > /dev/null 2>&1

    if systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME" || systemctl is-active --quiet hy2; then
        log_action "✅ Hysteria Client configured and running on port $HY_PORT (Foreign Server)."
        local server_ip=$(get_public_ipv4)
        echo "\n🎉 Hysteria Client on your Foreign Server is ready!"
        echo "--------------------------------------------------------------------------------"
        echo "  Foreign Server Details (for Iran Server to connect to):"
        echo "  Server IP      : ${server_ip}"
        echo "  Tunnel Port    : $HY_PORT"
        echo "  Password       : $HY_PASSWORD"
        echo "  Protocol       : $HY_PROTOCOL"
        echo "--------------------------------------------------------------------------------"
        echo "IMPORTANT: Open port $HY_PORT ($HY_PROTOCOL) in your Foreign Server's firewall!"
        echo "Now, go to your Iran Border Server and configure it as Hysteria Server."
    else
        log_action "❌ Failed to start Hysteria Client. Please check logs for details."
        echo "❌ Hysteria Client failed to start on Foreign Server."
        echo "   Check logs with 'journalctl -u $HYSTERIA_SERVICE_NAME -f' or 'journalctl -u hy2 -f'."
    fi
    press_enter_to_continue
}

# Configures Hysteria Server (on Iran Server)
function configure_iran_server() {
    echo "\n=== Configure Iran Server (Hysteria Server) ==="
    echo "This server will run Hysteria Server, which X-UI/Sanayi will connect to."
    echo "It will then forward traffic through the Hysteria tunnel to the Foreign Server."
    echo "Type 'back' at any prompt to return to the previous menu."
    
    if ! command -v hy2 &> /dev/null && ! command -v hysteria &> /dev/null; then
        echo "Hysteria is not installed. Please install it first (Option 1 in main menu)."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Foreign Server IP (The public IP of your Foreign Server): " FOREIGN_IP
    [[ "$FOREIGN_IP" == "back" ]] && return

    read -p "🔸 Foreign Hysteria Tunnel Port (e.g., 20000 - must match Foreign Server's Hysteria Client Port): " FOREIGN_HY_PORT
    [[ "$FOREIGN_HY_PORT" == "back" ]] && return
    if ! [[ "$FOREIGN_HY_PORT" =~ ^[0-9]+$ ]] || [ "$FOREIGN_HY_PORT" -lt 1 ] || [ "$FOREIGN_HY_PORT" -gt 65535 ]; then
        echo "Invalid port number. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Tunnel Password (Must match the password set on Foreign Server): " HY_PASSWORD
    [[ "$HY_PASSWORD" == "back" ]] && return
    if [ -z "$HY_PASSWORD" ]; then
        echo "Password cannot be empty. Please enter a password."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Tunnel Protocol (udp or tcp - must match Foreign Server's Hysteria Protocol, default: udp): " HY_PROTOCOL
    HY_PROTOCOL=${HY_PROTOCOL:-udp} # Set default to udp
    [[ "$HY_PROTOCOL" == "back" ]] && return
    if [[ "$HY_PROTOCOL" != "udp" && "$HY_PROTOCOL" != "tcp" ]]; then
        echo "Invalid protocol. Please choose 'udp' or 'tcp'."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Port for X-UI/Sanayi to connect to Hysteria (e.g., 40000): " XUI_PORT
    [[ "$XUI_PORT" == "back" ]] && return
    if ! [[ "$XUI_PORT" =~ ^[0-9]+$ ]] || [ "$XUI_PORT" -lt 1 ] || [ "$XUI_PORT" -gt 65535 ]; then
        echo "Invalid port number. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    mkdir -p "$HYSTERIA_CONFIG_DIR"
    HY_CONFIG_FILE="$HYSTERIA_CONFIG_DIR/iran_server_config.yaml"

    cat > "$HY_CONFIG_FILE" <<EOF
# Hysteria Server config for Iran (receives traffic from X-UI/Sanayi and forwards to foreign client)
listen: :$XUI_PORT
protocol: $HY_PROTOCOL
password: ["$HY_PASSWORD"]
# No TLS needed here for simple setup (X-UI/Sanayi connects locally)
# No Obfuscation/SNI for simple setup

# Forward traffic through the tunnel to the foreign server acting as Hysteria Client
forward:
  type: $HY_PROTOCOL
  server: $FOREIGN_IP:$FOREIGN_HY_PORT
EOF

    log_action "✅ Hysteria Server config created: $HY_CONFIG_FILE"
    
    log_action "🔄 Attempting to restart Hysteria service (Server Mode) on Iran Server..."
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl restart hy2 > /dev/null 2>&1

    if systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME" || systemctl is-active --quiet hy2; then
        log_action "✅ Hysteria Server configured and running on port $XUI_PORT (Iran Server)."
        local server_ip=$(get_public_ipv4)
        echo "\n🎉 Hysteria Server on your Iran Server is ready!"
        echo "--------------------------------------------------------------------------------"
        echo "  Iran Server Details (for X-UI/Sanayi to connect to):"
        echo "  Hysteria IP    : 127.0.0.1 (localhost)"
        echo "  Hysteria Port  : $XUI_PORT"
        echo "  Hysteria Pass  : $HY_PASSWORD"
        echo "  Hysteria Proto : $HY_PROTOCOL"
        echo ""
        echo "  Now, configure your X-UI/Sanayi on this server:"
        echo "  - Create an Outbound for Hysteria with these details (protocol: Hysteria, server: 127.0.0.1, port: $XUI_PORT, password: $HY_PASSWORD)."
        echo "  - Make sure your X-UI/Sanayi's Inbounds (e.g., VLESS/VMess) route traffic to this Hysteria Outbound."
        echo "--------------------------------------------------------------------------------"
        echo "IMPORTANT: Open port $XUI_PORT ($HY_PROTOCOL) in your Iran Server's firewall!"
        echo "Also, open the ports for your X-UI/Sanayi Inbounds (e.g., 443, 80) in your Iran Server's firewall!"
    else
        log_action "❌ Failed to start Hysteria Server. Please check logs for details."
        echo "❌ Hysteria Server failed to start on Iran Server."
        echo "   Check logs with 'journalctl -u $HYSTERIA_SERVICE_NAME -f' or 'journalctl -u hy2 -f'."
    fi
    press_enter_to_continue
}

# --- Tunnel Management Sub-Menu ---

# Lists existing tunnel configurations and offers deletion
function list_and_delete_tunnels() {
    echo "\n=== My ExitTunnel Configurations ==="
    local configs_found=0
    local i=1
    declare -A config_files_map # To map numbers to file paths

    mkdir -p "$HYSTERIA_CONFIG_DIR" # Ensure config directory exists
    
    local all_config_files=("$HYSTERIA_CONFIG_DIR"/*_config.yaml) # Simplified to catch both

    for config_file in "${all_config_files[@]}"; do
        if [ -f "$config_file" ]; then
            configs_found=1
            config_files_map["$i"]="$config_file"
            local filename=$(basename "$config_file")
            local role_display="Unknown Role"

            if [[ "$filename" == foreign_client_config.yaml ]]; then
                role_display="Foreign Server (Hysteria Client)"
            elif [[ "$filename" == iran_server_config.yaml ]]; then
                role_display="Iran Server (Hysteria Server)"
            fi

            echo -e "\n[$i] Role: $role_display | File: $filename"
            echo "    --- Details ---"
            cat "$config_file"
            echo "    ---------------"
            i=$((i+1))
        fi
    done

    if [ "$configs_found" -eq 0 ]; then
        echo "No ExitTunnel configurations found in $HYSTERIA_CONFIG_DIR."
    else
        echo -e "\n-----------------------------------------"
        read -p "Enter the number of the tunnel config to delete, or 'back' to return: " TUNNEL_NUM_TO_DELETE
        [[ "$TUNNEL_NUM_TO_DELETE" =~ ^[bB][aA][cC][kK]$ ]] && return

        if [[ "$TUNNEL_NUM_TO_DELETE" =~ ^[0-9]+$ ]] && [ -n "${config_files_map[$TUNNEL_NUM_TO_DELETE]}" ]; then
            local file_to_delete="${config_files_map[$TUNNEL_NUM_TO_DELETE]}"
            local config_name_to_delete=$(basename "$file_to_delete")
            
            read -p "Are you sure you want to delete '$config_name_to_delete'? (y/N): " CONFIRM_DELETE
            [[ "$CONFIRM_DELETE" =~ ^[bB][aA][cC][kK]$ ]] && return

            if [[ "$CONFIRM_DELETE" =~ ^[yY]$ ]]; then
                log_action "🗑 Deleting tunnel config: $file_to_delete"
                rm -f "$file_to_delete"
                log_action "✅ Config '$config_name_to_delete' deleted successfully."
                echo "Config '$config_name_to_delete' deleted."
                
                # Restart Hysteria service
                log_action "🔄 Restarting Hysteria service to apply changes..."
                systemctl restart "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl restart hy2 > /dev/null 2>&1
                if systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME" || systemctl is-active --quiet hy2; then
                    log_action "✅ Hysteria service restarted with updated configs."
                    echo "Hysteria service restarted with updated configurations."
                else
                    log_action "❌ Hysteria service failed to restart or is not running. Check logs if needed."
                    echo "Hysteria service restart attempt finished (it might not be running in this mode)."
                fi

            else
                log_action "❌ Deletion cancelled by user."
                echo "Deletion cancelled."
            fi
        else
            echo "Invalid config number. Please enter a valid number from the list or 'back'."
            log_action "Invalid config number entered for deletion: $TUNNEL_NUM_TO_DELETE."
        fi
    fi
    press_enter_to_continue
}

# --- Service Status & Logs ---
function check_hysteria_status() {
    echo "\n=== Hysteria Service Status ==="
    systemctl status "$HYSTERIA_SERVICE_NAME" --no-pager || systemctl status hy2 --no-pager
    echo "\n=== Last 10 Hysteria Service Logs (journalctl) ==="
    journalctl -u "$HYSTERIA_SERVICE_NAME" -n 10 --no-pager || journalctl -u hy2 -n 10 --no-pager
    echo "===============================\n"
    press_enter_to_continue
}

# --- Main Menu Logic ---
function main_menu() {
    while true; do
        display_header
        echo "Select an option:"
        echo "1) Install Hysteria"
        echo "2) ExitTunnel management"
        echo "3) Uninstall Hysteria and cleanup"
        echo "4) Exit"
        read -p "👉 Your choice: " CHOICE

        case $CHOICE in
            1)
                install_hysteria
                ;;
            2)
                tunnel_management_menu
                ;;
            3)
                uninstall_hysteria_and_cleanup
                ;;
            4)
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

# --- Tunnel Management Sub-Menu ---
function tunnel_management_menu() {
    while true; do
        display_header
        echo "==== ExitTunnel Management ===="
        echo "1) Configure this server as Foreign Server (Hysteria Client)"
        echo "2) Configure this server as Iran Server (Hysteria Server)"
        echo "3) List & Delete Tunnel Configurations"
        echo "4) Check Hysteria Service Status & Logs"
        echo "5) Back to Main Menu"
        read -p "👉 Your choice: " TUNNEL_CHOICE

        case $TUNNEL_CHOICE in
            1)
                configure_foreign_client
                ;;
            2)
                configure_iran_server
                ;;
            3)
                list_and_delete_tunnels
                ;;
            4)
                check_hysteria_status
                ;;
            5)
                return # Exit this sub-menu
                ;;
            *)
                echo "Invalid option. Please choose a number from the menu."
                press_enter_to_continue
                ;;
        esac
    done
}

# --- Start the script ---
main_menu
