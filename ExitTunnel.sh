#!/bin/bash

# ==============================================================================
# ExitTunnel Socks5 Manager - Developed by @mr_bxs
# ==============================================================================
# This script sets up a simple and secure Socks5 tunnel using Dante Server.
# It configures one server as Socks5 Server (Foreign side) and provides
# instructions for setting up X-UI/Sanayi on the Iran side to use this tunnel.
#
# Features: Persistent services, simple 'exittunnel' command, Socks5 with Auth.
#
# GitHub: [Upload to GitHub & put your link here]
# Telegram ID: @mr_bxs
# Script Version: 10.0 (ExitTunnel Socks5 Auth)
# ==============================================================================

# --- Global Variables & Configuration ---
LOG_FILE="/var/log/exittunnel_socks5.log"
SOCKS5_CONFIG_DIR="/etc/dante" # Central directory for Dante Socks5 configs
SOCKS5_SERVICE_NAME="danted" # Systemd service name for Dante Server
SCRIPT_VERSION="10.0"
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
    echo "Tunnel script based on Socks5 Proxy with Authentication"
    echo "========================================"
    echo " 🌐 Server Information"
    echo "========================================"
    echo " IPv4 Address: $(get_public_ipv4)"
    echo " IPv6 Address: $(get_public_ipv6)"
    echo " Script Version: $SCRIPT_VERSION"
    echo "========================================\n"
}

# --- Core Functions ---

# Installs Dante Server (Socks5 Proxy)
function install_dante_server() {
    log_action "📥 Installing 'dante-server' (Socks5 Proxy)..."
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

# Configures Socks5 Server (on Foreign Server)
function configure_foreign_socks5_server() {
    echo "\n=== Configure Foreign Server (Socks5 Proxy) ==="
    echo "This server will run a Socks5 proxy to provide internet access."
    echo "Type 'back' at any prompt to return to the previous menu."

    if ! command -v danted &> /dev/null; then
        echo "'dante-server' is not installed. Installing now..."
        if ! install_dante_server; then
            echo "Failed to install dante-server. Cannot create tunnel."
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
    SOCKS5_CONF_FILE="$SOCKS5_CONFIG_DIR/danted.conf"
    SOCKS5_USERS_FILE="$SOCKS5_CONFIG_DIR/users"

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
external: ${get_public_ipv4}

# Authentication method
method: username none

# User authentication
user.libwrap: disable

# Allow connections from any IP to this SOCKS5 proxy
clientmethod: none
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}

# Allow connections from the Socks5 proxy to any destination
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
EOF
    log_action "✅ Dante Socks5 config created: $SOCKS5_CONF_FILE"

    # Store user/pass for listing (not directly used by dante, but for info)
    echo "${SOCKS5_USERNAME}:${SOCKS5_PASSWORD}:${SOCKS5_PORT}" > "$TUNNEL_CONFIG_DIR/socks5_foreign_server.conf"

    log_action "🔄 Attempting to restart Dante Socks5 service..."
    systemctl daemon-reload > /dev/null 2>&1
    systemctl restart "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1

    if systemctl is-active --quiet "$SOCKS5_SERVICE_NAME"; then
        log_action "✅ Dante Socks5 Server configured and running on port $SOCKS5_PORT (Foreign Server)."
        local server_ip=$(get_public_ipv4)
        
        echo "\n🎉 Dante Socks5 Server on your Foreign Server is ready!"
        echo "--------------------------------------------------------------------------------"
        echo " Connection Details for Iran Server (X-UI/Sanayi Outbound):"
        echo " Proxy Type : Socks5"
        echo " Server IP : ${server_ip}"
        echo " Server Port : $SOCKS5_PORT"
        echo " Username : $SOCKS5_USERNAME"
        echo " Password : $SOCKS5_PASSWORD"
        echo "--------------------------------------------------------------------------------"
        echo "IMPORTANT: Open port $SOCKS5_PORT (TCP) in your Foreign Server's firewall!"
        echo "Now, go to your Iran Server and configure X-UI/Sanayi Outbound to use these details."
    else
        log_action "❌ Failed to start Dante Socks5 Server. Please check logs for details."
        echo "❌ Dante Socks5 Server failed to start."
        echo " Check logs with 'journalctl -u $SOCKS5_SERVICE_NAME -f'."
    fi
    press_enter_to_continue
}

# --- Tunnel Management Functions ---

# Lists existing tunnel configurations and offers deletion
function list_and_delete_tunnels() {
    echo "\n=== My ExitTunnel Configurations (Socks5 Server) ==="
    local configs_found=0
    
    mkdir -p "$TUNNEL_CONFIG_DIR"
    
    if [ -f "$TUNNEL_CONFIG_DIR/socks5_foreign_server.conf" ]; then
        configs_found=1
        local config_data=$(cat "$TUNNEL_CONFIG_DIR/socks5_foreign_server.conf")
        local username=$(echo "$config_data" | awk -F':' '{print $1}')
        local password=$(echo "$config_data" | awk -F':' '{print $2}')
        local port=$(echo "$config_data" | awk -F':' '{print $3}')
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

    if [ "$configs_found" -eq 0 ]; then
        echo "No ExitTunnel Socks5 server configuration found."
    else
        echo -e "\n-----------------------------------------"
        read -p "Do you want to delete this Socks5 tunnel config? (y/N/back): " DELETE_CHOICE
        [[ "$DELETE_CHOICE" =~ ^[bB][aA][cC][kK]$ ]] && return
        
        if [[ "$DELETE_CHOICE" =~ ^[yY]$ ]]; then
            log_action "🗑 Stopping and disabling Dante Socks5 service..."
            systemctl stop "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1
            systemctl disable "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1
            
            log_action "🗑 Deleting Dante config file: $SOCKS5_CONFIG_DIR/danted.conf and related files..."
            rm -f "$SOCKS5_CONFIG_DIR/danted.conf"
            rm -f "$TUNNEL_CONFIG_DIR/socks5_foreign_server.conf" # Remove our tracking file
            
            # Optionally remove the system user created for Dante
            read -p "Do you want to remove the Socks5 user '$username' from the system? (y/N): " REMOVE_USER
            if [[ "$REMOVE_USER" =~ ^[yY]$ ]]; then
                log_action "🗑 Removing system user '$username'..."
                sudo userdel "$username" > /dev/null 2>&1
                log_action "✅ System user '$username' removed."
            fi

            systemctl daemon-reload > /dev/null 2>&1 # Reload systemd
            echo "Dante Socks5 tunnel config deleted and service stopped."
            log_action "✅ Dante Socks5 tunnel config deleted."
        else
            log_action "❌ Deletion cancelled by user."
            echo "Deletion cancelled."
        fi
    fi
    press_enter_to_continue
}

# --- Service Status & Logs ---
function check_socks5_status() {
    echo "\n=== Dante Socks5 Service Status & Logs ==="
    systemctl status "$SOCKS5_SERVICE_NAME" --no-pager
    echo "\n=== Last 10 Dante Socks5 Service Logs (journalctl) ==="
    journalctl -u "$SOCKS5_SERVICE_NAME" -n 10 --no-pager
    echo "===============================\n"
    press_enter_to_continue
}

# --- Main Menu Logic ---
function main_menu() {
    while true; do
        display_header
        echo "Select an option:"
        echo "1) Install Dante Server (Socks5 Proxy)"
        echo "2) ExitTunnel management (Socks5 Server)"
        echo "3) Uninstall Dante Server and cleanup"
        echo "4) Exit"
        read -p "👉 Your choice: " CHOICE

        case $CHOICE in
            1)
                install_dante_server
                ;;
            2)
                tunnel_management_menu
                ;;
            3)
                uninstall_dante_server_and_cleanup
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
        echo "==== ExitTunnel Management (Socks5 Proxy) ===="
        echo "1) Configure this server as Socks5 Server (Foreign Server)"
        echo "2) List & Delete Socks5 Tunnel"
        echo "3) Check Socks5 Service Status & Logs"
        echo "4) Back to Main Menu"
        read -p "👉 Your choice: " TUNNEL_CHOICE

        case $TUNNEL_CHOICE in
            1)
                configure_foreign_socks5_server
                ;;
            2)
                list_and_delete_tunnels
                ;;
            3)
                check_socks5_status
                ;;
            4)
                return # Exit this sub-menu
                ;;
            *)
                echo "Invalid option. Please choose a number from the menu."
                press_enter_to_continue
                ;;
        esac
    done
}

# --- Uninstall All Tunnels & Dante ---
function uninstall_dante_server_and_cleanup() {
    echo "\n=== Uninstall Dante Server and Cleanup ==="
    read -p "Are you sure you want to remove ALL Socks5 tunnel configs, stop service, and uninstall Dante? (y/N): " CONFIRM_CLEAN
    if [[ "$CONFIRM_CLEAN" =~ ^[yY]$ ]]; then
        log_action "🗑 Stopping and disabling Dante service..."
        systemctl stop "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1
        systemctl disable "$SOCKS5_SERVICE_NAME" > /dev/null 2>&1

        log_action "🗑 Removing Dante configs and user..."
        if [ -f "$TUNNEL_CONFIG_DIR/socks5_foreign_server.conf" ]; then
            local username_to_remove=$(head -n 1 "$TUNNEL_CONFIG_DIR/socks5_foreign_server.conf" | awk -F':' '{print $1}')
            if id -u "$username_to_remove" >/dev/null 2>&1; then
                log_action "🗑 Removing system user '$username_to_remove'..."
                sudo userdel "$username_to_remove" > /dev/null 2>&1
            fi
        fi
        rm -rf "$SOCKS5_CONFIG_DIR"
        rm -rf "$TUNNEL_CONFIG_DIR"
        systemctl daemon-reload > /dev/null 2>&1
        log_action "✅ All Socks5 configs removed and service stopped."

        log_action "🗑 Attempting to uninstall 'dante-server'..."
        if command -v apt-get &> /dev/null; then
            sudo apt-get remove dante-server -y > /dev/null 2>&1
            sudo apt-get autoremove -y > /dev/null 2>&1
        elif command -v yum &> /dev/null; then
            sudo yum remove dante-server -y > /dev/null 2>&1
            sudo yum autoremove -y > /dev/null 2>&1
        elif command -v dnf &> /dev/null; then
            sudo dnf remove dante-server -y > /dev/null 2>&1
            sudo dnf autoremove -y > /dev/null 2>&1
        else
            log_action "⚠️ Warning: Could not detect package manager to uninstall 'dante-server'. Please uninstall it manually."
            echo "Warning: Could not detect package manager to uninstall 'dante-server'. Please uninstall it manually."
        fi
        log_action "✅ 'dante-server' uninstallation attempted."
        echo "All Socks5 configurations and services stopped. 'dante-server' uninstallation attempted."
    else
        echo "Cleanup cancelled."
    fi
    press_enter_to_continue
}


# --- Initial Setup for Persistent Command ---
function setup_persistent_command() {
    if [ ! -f "$SYMLINK_PATH" ] || [ "$(readlink "$SYMLINK_PATH")" != "$SCRIPT_PATH" ]; then
        log_action "Configuring persistent 'exittunnel' command."
        sudo cp "$0" "$SCRIPT_PATH" # Copy the current running script to a persistent location
        sudo chmod +x "$SCRIPT_PATH"
        sudo ln -sf "$SCRIPT_PATH" "$SYMLINK_PATH" # Create a symlink to make it accessible system-wide
        echo "✅ 'exittunnel' command is now set up. You can run the script by typing 'exittunnel' from anywhere."
        press_enter_to_continue
    fi
}

# --- Start the script ---
# Check if the script is being run for the first time or if the persistent command needs setup
if [ "$(basename "$0")" == "exittunnel.sh" ] || [ "$(basename "$0")" == "ExitTunnel.sh" ]; then
    setup_persistent_command
fi
main_menu

