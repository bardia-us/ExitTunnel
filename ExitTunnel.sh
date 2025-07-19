#!/bin/bash

# ==============================================================================
# Hysteria Tunnel Manager - Inspired by HPulse
# ==============================================================================
# Developed for secure and stable direct tunneling with Hysteria.
# This script configures Hysteria as a SERVER on your Foreign Server.
#
# GitHub: [Your GitHub Repo Link will go here after you upload it]
# Telegram ID: @mr_bxs
# Script Version: 3.0
# ==============================================================================

# --- Global Variables & Configuration ---
LOG_FILE="/var/log/hysteria_manager.log"
HYSTERIA_CONFIG_DIR="/etc/hysteria" # Central directory for Hysteria configs
HYSTERIA_SERVICE_NAME="hysteria-server" # Common service name for Hysteria 2.x

# --- Helper Functions ---

# Function to get the server's public IPv4 address
function get_public_ipv4() {
    local ip=$(curl -s4 --connect-timeout 5 "http://ifconfig.me/ip" || \
               curl -s4 --connect-timeout 5 "http://ipecho.net/plain" || \
               curl -s4 --connect-timeout 5 "http://checkip.amazonaws.com" || \
               curl -s4 --connect-timeout 5 "http://icanhazip.com")
    echo "${ip:-N/A}"
}

# Function to get the server's public IPv6 address
function get_public_ipv6() {
    local ip6=$(curl -s6 --connect-timeout 5 "http://ifconfig.me/ip" || \
                curl -s6 "http://ipecho.net/plain" || \
                curl -s6 "http://checkip.amazonaws.com" || \
                curl -s6 "http://icanhazip.com")
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

# --- Display Functions ---

# Displays script and server information at the start
function display_header() {
    clear # Clear screen for clean display
    echo "================================================================================"
    echo "Developed by @mr_bxs | GitHub: [Upload to GitHub & put your link here]"
    echo "Telegram Channel => @mr_bxs"
    echo "Tunnel script based on Hysteria 2"
    echo "========================================"
    echo "     🌐 Server Information"
    echo "========================================"
    echo "  IPv4 Address: $(get_public_ipv4)"
    echo "  IPv6 Address: $(get_public_ipv6)"
    echo "  Script Version: $SCRIPT_VERSION"
    echo "========================================\n"
}

# --- Core Functions ---

# Installs Hysteria 2.x
function install_hysteria() {
    log_action "📥 Attempting to install Hysteria (v2.x compatible) on this server..."
    if ! command -v curl &> /dev/null; then
        log_action "❌ Error: 'curl' is not installed. Please install it first (e.g., sudo apt install curl or sudo yum install curl)."
        press_enter_to_continue
        return 1
    fi

    bash <(curl -fsSL https://get.hy2.sh/)
    if [ $? -eq 0 ]; then
        log_action "✅ Hysteria installed successfully."
        echo "Hysteria installation completed. Please return to the main menu and configure your tunnel."
    else
        log_action "❌ Hysteria installation failed. Please check your internet connection and try again."
        echo "Hysteria installation failed."
    fi
    press_enter_to_continue
}

# Generates a self-signed TLS certificate
function generate_tls_cert() {
    log_action "🔑 Generating self-signed TLS certificate for Hysteria Server..."
    mkdir -p "$HYSTERIA_CONFIG_DIR"
    # Ensure previous certs are removed to avoid conflicts
    rm -f "$HYSTERIA_CONFIG_DIR/ca.key" "$HYSTERIA_CONFIG_DIR/ca.crt"

    openssl genrsa -out "$HYSTERIA_CONFIG_DIR/ca.key" 2048 > /dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$HYSTERIA_CONFIG_DIR/ca.key" -out "$HYSTERIA_CONFIG_DIR/ca.crt" -subj "/CN=Hysteria_Tunnel" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_action "❌ Failed to generate TLS certificate."
        echo "Failed to generate TLS certificate. Hysteria will not start without it."
        return 1
    fi
    log_action "✅ TLS certificate generated."
    return 0
}

# Creates a new Hysteria Server tunnel configuration
function create_new_tunnel() {
    echo "\n=== Create New Hysteria Server Tunnel ==="
    echo "This tunnel will be directly accessible from your clients."
    echo "Type 'back' at any prompt to return to the previous menu."

    # Check if Hysteria is installed
    if ! command -v hy2 &> /dev/null; then
        echo "Hysteria is not installed. Please install it first (Option 1 in main menu)."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Enter a Tunnel Name (e.g., my_hy_tunnel): " TUNNEL_NAME
    [[ "$TUNNEL_NAME" == "back" ]] && return

    # Check for existing tunnel with the same name
    if [ -f "$HYSTERIA_CONFIG_DIR/${TUNNEL_NAME}_server.yaml" ]; then
        echo "Error: A tunnel with this name already exists. Please choose a different name."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Choose a Port for Hysteria (e.g., 443, 8443): " HY_PORT
    [[ "$HY_PORT" == "back" ]] && return
    if ! [[ "$HY_PORT" =~ ^[0-9]+$ ]] || [ "$HY_PORT" -lt 1 ] || [ "$HY_PORT" -gt 65535 ]; then
        echo "Invalid port number. Please enter a number between 1 and 65535."
        press_enter_to_continue
        return
    fi

    read -p "🔸 Set a Strong Password for Hysteria: " HY_PASSWORD
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

    read -p "🔸 Choose an Obfuscation Password (optional, leave blank for no obfuscation): " OBFS_PASSWORD
    [[ "$OBFS_PASSWORD" == "back" ]] && return

    read -p "🔸 Do you want to use a custom SNI (e.g., google.com)? (Leave blank for default): " CUSTOM_SNI
    [[ "$CUSTOM_SNI" == "back" ]] && return

    if ! generate_tls_cert; then # Generate certs if not already done or failed
        press_enter_to_continue
        return
    fi

    HY_CONFIG_FILE="$HYSTERIA_CONFIG_DIR/${TUNNEL_NAME}_server.yaml"

    cat > "$HY_CONFIG_FILE" <<EOF
listen: :$HY_PORT
protocol: $HY_PROTOCOL
password: ["$HY_PASSWORD"]
tls:
  cert: $HYSTERIA_CONFIG_DIR/ca.crt
  key: $HYSTERIA_CONFIG_DIR/ca.key
EOF

    if [ -n "$CUSTOM_SNI" ]; then
        echo "  sni: $CUSTOM_SNI" >> "$HY_CONFIG_FILE"
    fi

    if [ -n "$OBFS_PASSWORD" ]; then
        echo "obfs:" >> "$HY_CONFIG_FILE"
        echo "  password: "$OBFS_PASSWORD"" >> "$HY_CONFIG_FILE"
    fi

    log_action "✅ Hysteria Server config created: $HY_CONFIG_FILE"
    
    # Reload systemd and restart Hysteria service
    log_action "🔄 Attempting to restart Hysteria service..."
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl restart hy2 > /dev/null 2>&1

    if systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME" || systemctl is-active --quiet hy2; then
        log_action "✅ Hysteria Server configured and running on port $HY_PORT."
        local server_ip=$(get_public_ipv4)
        echo "\n🎉 Hysteria Server for tunnel '$TUNNEL_NAME' is ready!"
        echo "----------------------------------------------------------------"
        echo "Connection Details:"
        echo "  Server IP      : ${server_ip}"
        echo "  Port           : $HY_PORT"
        echo "  Password       : $HY_PASSWORD"
        echo "  Protocol       : $HY_PROTOCOL"
        if [ -n "$OBFS_PASSWORD" ]; then
            echo "  Obfuscation    : $OBFS_PASSWORD"
        fi
        if [ -n "$CUSTOM_SNI" ]; then
            echo "  Custom SNI     : $CUSTOM_SNI"
        fi
        echo "  Cert (Base64)  : $(base64 -w 0 "$HYSTERIA_CONFIG_DIR/ca.crt")" # For client config
        echo "----------------------------------------------------------------"
        echo "IMPORTANT: Remember to open port $HY_PORT in your server's firewall (e.g., ufw, firewalld)."
        echo "You can now use these details to connect from your Hysteria client or other proxy tools."
    else
        log_action "❌ Failed to start Hysteria Server. Please check logs for details."
        echo "❌ Hysteria Server failed to start for tunnel '$TUNNEL_NAME'."
        echo "   Check logs with 'journalctl -u $HYSTERIA_SERVICE_NAME -f' or 'journalctl -u hy2 -f'."
    fi
    press_enter_to_continue
}

# Lists existing tunnel configurations and offers deletion
function list_and_delete_tunnels() {
    echo "\n=== My Hysteria Tunnel Configurations ==="
    local configs_found=0
    local i=1
    declare -A config_files_map # To map numbers to file paths

    mkdir -p "$HYSTERIA_CONFIG_DIR" # Ensure config directory exists
    
    for config_file in "$HYSTERIA_CONFIG_DIR"/*_server.yaml; do
        if [ -f "$config_file" ]; then
            configs_found=1
            local tunnel_name=$(basename "$config_file" | sed 's/_server.yaml$//')
            config_files_map["$i"]="$config_file"

            echo -e "\n[$i] Tunnel Name: $tunnel_name"
            echo "    Path: $config_file"
            echo "    --- Connection Details ---"
            local config_content=$(cat "$config_file")
            local hy_port=$(echo "$config_content" | grep 'listen:' | awk '{print $2}' | sed 's/:/ /g')
            local hy_password=$(echo "$config_content" | grep 'password:' | head -n 1 | sed 's/.*\["\(.*\)"\].*/\1/' | sed 's/.*\[\(.*\)\].*/\1/') # Handles both with/without quotes
            local hy_protocol=$(echo "$config_content" | grep 'protocol:' | awk '{print $2}')
            local obfs_password=$(echo "$config_content" | grep -A 1 'obfs:' | grep 'password:' | awk '{print $2}')
            local custom_sni=$(echo "$config_content" | grep 'sni:' | awk '{print $2}')
            local server_ip=$(get_public_ipv4)
            local cert_base64=$(base64 -w 0 "$HYSTERIA_CONFIG_DIR/ca.crt" 2>/dev/null || echo "N/A")

            echo "      Server IP   : ${server_ip}"
            echo "      Port        : $hy_port"
            echo "      Password    : $hy_password"
            echo "      Protocol    : $hy_protocol"
            if [ -n "$obfs_password" ]; then
                echo "      Obfuscation : $obfs_password"
            fi
            if [ -n "$custom_sni" ]; then
                echo "      Custom SNI  : $custom_sni"
            fi
            echo "      Cert (Base64): $cert_base64"
            echo "    --------------------------"
            i=$((i+1))
        fi
    done

    if [ "$configs_found" -eq 0 ]; then
        echo "No Hysteria server configurations found."
    else
        echo -e "\n-----------------------------------------"
        read -p "Enter the number of the tunnel to delete, or 'back' to return: " TUNNEL_NUM_TO_DELETE
        [[ "$TUNNEL_NUM_TO_DELETE" == "back" ]] && return

        if [[ "$TUNNEL_NUM_TO_DELETE" =~ ^[0-9]+$ ]] && [ -n "${config_files_map[$TUNNEL_NUM_TO_DELETE]}" ]; then
            local file_to_delete="${config_files_map[$TUNNEL_NUM_TO_DELETE]}"
            local tunnel_name_to_delete=$(basename "$file_to_delete" | sed 's/_server.yaml$//')
            
            read -p "Are you sure you want to delete tunnel '$tunnel_name_to_delete'? (y/N): " CONFIRM_DELETE
            [[ "$CONFIRM_DELETE" == "back" ]] && return

            if [[ "$CONFIRM_DELETE" =~ ^[yY]$ ]]; then
                log_action "🗑 Deleting tunnel config: $file_to_delete"
                rm -f "$file_to_delete"
                log_action "✅ Tunnel '$tunnel_name_to_delete' deleted successfully."
                echo "Tunnel '$tunnel_name_to_delete' deleted."

                # If there are no more configs, stop the service. Otherwise, restart to apply changes.
                if [ $(ls -1 "$HYSTERIA_CONFIG_DIR"/*_server.yaml 2>/dev/null | wc -l) -eq 0 ]; then
                    log_action "No more Hysteria configs found. Stopping Hysteria service."
                    systemctl stop "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl stop hy2 > /dev/null 2>&1
                    echo "Hysteria service stopped as no more configurations are present."
                else
                    log_action "🔄 Restarting Hysteria service to apply changes..."
                    systemctl restart "$HYSTERIA_SERVICE_NAME" > /dev/null 2>&1 || systemctl restart hy2 > /dev/null 2>&1
                    if systemctl is-active --quiet "$HYSTERIA_SERVICE_NAME" || systemctl is-active --quiet hy2; then
                        log_action "✅ Hysteria service restarted with updated configs."
                        echo "Hysteria service restarted with updated configurations."
                    else
                        log_action "❌ Hysteria service failed to restart after config deletion. Check logs."
                        echo "Hysteria service failed to restart. Check logs for errors."
                    fi
                fi
            else
                log_action "❌ Deletion cancelled by user."
                echo "Deletion cancelled."
            fi
        else
            echo "Invalid tunnel number. Please enter a valid number from the list or 'back'."
            log_action "Invalid tunnel number entered for deletion: $TUNNEL_NUM_TO_DELETE."
        fi
    fi
    press_enter_to_continue
}

# --- Certificate Management ---
function certificate_management_menu() {
    while true; do
        echo "\n=== Certificate Management ==="
        echo "1. Regenerate Self-Signed TLS Certificate (for Hysteria)"
        echo "2. Back to Main Menu"
        read -p "Choose an option: " CERT_CHOICE

        case $CERT_CHOICE in
            1)
                generate_tls_cert
                if [ $? -eq 0 ]; then
                    echo "Certificate regenerated. Remember to restart Hysteria service for changes to take effect."
                fi
                press_enter_to_continue
                ;;
            2)
                return
                ;;
            *)
                echo "Invalid option."
                press_enter_to_continue
                ;;
        esac
    done
}

# --- Service Status & Logs ---
function check_hysteria_status() {
    echo "\n=== Hysteria Service Status ==="
    systemctl status "$HYSTERIA_SERVICE_NAME" --no-pager || systemctl status hy2 --no-pager
    echo "\n=== Last 10 Hysteria Service Logs ==="
    journalctl -u "$HYSTERIA_SERVICE_NAME" -n 10 --no-pager || journalctl -u hy2 -n 10 --no-pager
    echo "===============================\n"
    press_enter_to_continue
}

# --- Uninstall & Cleanup ---
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

# --- Main Menu Logic ---
function main_menu() {
    while true; do
        display_header # Always display header for a clean start
        echo "Select an option:"
        echo "1) Install Hysteria"
        echo "2) Hysteria tunnel management"
        echo "3) Certificate management"
        echo "4) Uninstall Hysteria and cleanup"
        echo "5) Exit"
        read -p "👉 Your choice: " CHOICE

        case $CHOICE in
            1)
                install_hysteria
                ;;
            2)
                tunnel_management_menu
                ;;
            3)
                certificate_management_menu
                ;;
            4)
                uninstall_hysteria_and_cleanup
                ;;
            5)
                log_action "Exiting script."
                echo "Exiting Hysteria Tunnel Manager. Goodbye!"
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
        display_header # Re-display header for sub-menu context
        echo "==== Hysteria Tunnel Management ===="
        echo "1) Create Tunnel (Foreign Server)"
        echo "2) List & Delete Tunnels"
        echo "3) Check Hysteria Service Status" # Moved here for easy access
        echo "4) View Script Log" # Moved here for easy access
        echo "5) Back to Main Menu"
        read -p "👉 Your choice: " TUNNEL_CHOICE

        case $TUNNEL_CHOICE in
            1)
                create_new_tunnel
                ;;
            2)
                list_and_delete_tunnels
                ;;
            3)
                check_hysteria_status
                ;;
            4)
                view_script_log
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
