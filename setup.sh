#!/bin/bash

set -euo pipefail

trap 'echo "Error on line $LINENO. Check log at: $LOGFILE"; exit 1' ERR

# Set up logging
LOGFILE="/root/vps-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE")
exec 2>&1

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# config
NEW_USER=""
TEMP_PASS=""
TAILSCALE_AUTH_KEY=""
TS_HOSTNAME=""
TS_IP=""

print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[*]${NC} $1"
}

# Start script
echo "==================================="
echo "VPS Setup Script"
echo "Started at: $(date)"
echo "==================================="
echo ""

# Check running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

# updating
print_status "Installing required packages..."
apt-get update &>/dev/null && apt-get install -y jq &>/dev/null || true

# hostname
echo ""
print_status "System Configuration"
read -p "Set hostname (or press Enter to skip): " new_hostname
if [ -n "$new_hostname" ]; then
    hostnamectl set-hostname "$new_hostname"
    print_status "Hostname set to $new_hostname"
fi

# user config
echo ""
print_status "User Configuration"
read -p "Enter username for new sudo user: " NEW_USER
while [ -z "$NEW_USER" ]; do
    print_error "Username cannot be empty"
    read -p "Enter username for new sudo user: " NEW_USER
done

# Check if user already exists
if id "$NEW_USER" &>/dev/null; then
    print_warning "User $NEW_USER already exists. Skipping user creation."
else
    # Create new user + home directory
    print_status "Creating user $NEW_USER..."
    useradd -m -s /bin/bash "$NEW_USER"
    
    # Set password
    print_status "Setting temporary password for $NEW_USER..."
    TEMP_PASS=$(openssl rand -base64 12)
    echo "$NEW_USER:$TEMP_PASS" | chpasswd
    
    # display temp password
    echo ""
    print_warning "TEMPORARY PASSWORD FOR $NEW_USER:"
    echo -e "${YELLOW}$TEMP_PASS${NC}"
    echo ""
    print_warning "SAVE THIS PASSWORD! You'll need it for first login."
    echo ""
    
    # force password change
    passwd -e "$NEW_USER"
fi

# Add user to sudo group
print_status "Adding $NEW_USER to sudo group..."
usermod -aG sudo "$NEW_USER"

print_status "Configuring sudo permissions..."
echo "%sudo ALL=(ALL:ALL) ALL" > /etc/sudoers.d/sudo-group
chmod 440 /etc/sudoers.d/sudo-group

# Create ssh directory
print_status "Setting up SSH directory for $NEW_USER..."
USER_HOME="/home/$NEW_USER"
SSH_DIR="$USER_HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"

# Copy roots authorized_keys to new user
if [ -f /root/.ssh/authorized_keys ]; then
    print_status "Copying SSH keys from root to $NEW_USER..."
    cp /root/.ssh/authorized_keys "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown "$NEW_USER:$NEW_USER" "$SSH_DIR/authorized_keys"
else
    print_warning "No SSH keys found for root user."
    touch "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown "$NEW_USER:$NEW_USER" "$SSH_DIR/authorized_keys"
fi

# adding ssh key
echo ""
read -p "Do you have an SSH public key to add for $NEW_USER? (y/n): " add_key
if [[ "$add_key" == "y" ]]; then
    echo "Paste your SSH public key (one line):"
    read -r ssh_key
    if [ -n "$ssh_key" ]; then
        echo "$ssh_key" >> "$SSH_DIR/authorized_keys"
        print_status "SSH key added successfully"
    else
        print_warning "No key provided, skipping"
    fi
fi

# disable root login
print_status "Configuring SSH security..."
SSHD_CONFIG="/etc/ssh/sshd_config"

# backup sshd_config
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"

# ssh configuration
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

# add settings
grep -q "^PermitRootLogin" "$SSHD_CONFIG" || echo "PermitRootLogin no" >> "$SSHD_CONFIG"
grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"

# Test ssh config
print_status "Testing SSH configuration..."
sshd -t
if [ $? -eq 0 ]; then
    print_status "SSH configuration is valid"
else
    print_error "SSH configuration test failed! Restoring backup..."
    mv "$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)" "$SSHD_CONFIG"
    exit 1
fi

# automatic security updates
echo ""
read -p "Enable automatic security updates? (y/n): " enable_updates
if [[ "$enable_updates" == "y" ]]; then
    print_status "Configuring automatic security updates..."
    apt-get install -y unattended-upgrades &>/dev/null
    echo 'Unattended-Upgrade::Automatic-Reboot "false";' > /etc/apt/apt.conf.d/50unattended-upgrades
    echo 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    dpkg-reconfigure -plow unattended-upgrades
    print_status "Automatic security updates enabled"
fi

# Check if tailscale is installed
if command -v tailscale &> /dev/null; then
    print_warning "Tailscale already installed, skipping installation"
else
    # install Tailscale
    print_status "Installing Tailscale..."
    
    # detect distribution
    if [ -f /etc/debian_version ]; then
        # Debian/Ubuntu
        curl -fsSL https://tailscale.com/install.sh | sh
    elif [ -f /etc/redhat-release ]; then
        # RHEL/CentOS/Fedora
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        print_error "Unsupported distribution. Please install Tailscale manually."
        exit 1
    fi
fi

# start Tailscale
print_status "Starting Tailscale service..."
systemctl enable --now tailscaled

# tailscale auth key (required)
echo ""
print_status "Tailscale Setup"
print_warning "Get an auth key from: https://login.tailscale.com/admin/settings/keys"
echo "Recommended settings"
echo "  - Reusable: No"
echo "  - Pre-authorized: Yes"
echo "  - Ephemeral: No"
echo "  - Tags: tag:server (optional)"
echo ""

# keep asking 
while [ -z "$TAILSCALE_AUTH_KEY" ]; do
    read -s -p "Enter your Tailscale auth key (required): " TAILSCALE_AUTH_KEY
    echo ""
    
    if [ -z "$TAILSCALE_AUTH_KEY" ]; then
        print_error "Auth key is required. Please get one from the link above."
    fi
done

print_status "Connecting to Tailscale using auth key..."
tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh

# clear the auth key from memory
TAILSCALE_AUTH_KEY=""

# wait
sleep 5

# check connection
if tailscale status &>/dev/null; then
    TS_IP=$(tailscale ip -4 2>/dev/null || echo "Not connected")
    TS_HOSTNAME=$(tailscale status --json | jq -r '.Self.HostName' 2>/dev/null || echo "Unknown")
    
    print_status "Tailscale connected successfully!"
    echo "  Tailscale IP: $TS_IP"
    echo "  Tailscale hostname: $TS_HOSTNAME"
    echo ""
    print_warning "You can now SSH using: ssh $NEW_USER@$TS_HOSTNAME"
    if [ -n "$TEMP_PASS" ]; then
        echo "  Password: $TEMP_PASS"
    fi
else
    print_error "Tailscale connection failed. You may need to run 'tailscale up --ssh' manually."
fi

# lock root account
print_status "Locking root account..."
passwd -l root

# restart ssh 
print_status "Restarting SSH service..."
systemctl restart ssh
# restart ssh.socket
systemctl restart ssh.socket 2>/dev/null || true

# Disable ssh
if [ -n "$TS_HOSTNAME" ] && [ "$TS_HOSTNAME" != "Unknown" ]; then
    if tailscale status &>/dev/null; then
        echo ""
        print_status "Tailscale SSH is working!"
        echo ""
        echo "Test Tailscale SSH from another terminal:"
        echo -e "${YELLOW}ssh $NEW_USER@$TS_HOSTNAME${NC}"
        if [ -n "$TEMP_PASS" ]; then
            echo ""
            echo "Reminder - Temporary password for $NEW_USER:"
            echo -e "${YELLOW}$TEMP_PASS${NC}"
        fi
        echo ""
        echo "If it works and you want maximum security, you can disable traditional SSH."
        echo ""
        read -p "Disable traditional SSH (port 22)? Only 'yes' will disable it: " confirm
        
        if [[ "$confirm" == "yes" ]]; then
            print_status "Stopping and disabling traditional SSH service..."
            
            systemctl stop ssh.socket 2>/dev/null || true
            systemctl stop ssh
            
            systemctl disable ssh.socket 2>/dev/null || true
            systemctl disable ssh
            
            echo ""
            print_status "Traditional SSH has been DISABLED!"
            echo ""
            echo "═══════════════════════════════════════════════════════════════"
            print_warning "CRITICAL INFORMATION - SAVE THIS:"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""
            echo "  The ONLY way to access this server is now:"
            echo -e "  ${GREEN}ssh $NEW_USER@$TS_HOSTNAME${NC}"
            echo ""
            echo "  If you need to re-enable traditional SSH in an emergency:"
            echo "  1. Connect via Tailscale SSH"
            echo "  2. Run: sudo systemctl enable ssh ssh.socket && sudo systemctl start ssh"
            echo ""
        else
            print_status "Traditional SSH remains active (port 22 still open)."
            echo "To disable it later, run:"
            echo "  sudo systemctl stop ssh.socket ssh"
            echo "  sudo systemctl disable ssh.socket ssh"
        fi
    else
        print_error "Tailscale connection lost! Keeping traditional SSH enabled for safety."
    fi
fi

print_status "Setup complete!"
echo ""
print_warning "IMPORTANT NOTES:"
echo "1. The root account has been locked"
echo "2. SSH root login has been disabled"
echo "3. User '$NEW_USER' has been created with sudo privileges"
echo ""
if [ -n "$TS_HOSTNAME" ] && [ "$TS_HOSTNAME" != "Unknown" ]; then
    if systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket 2>/dev/null; then
        echo "4. Tailscale has been connected with SSH enabled"
        echo "5. Traditional SSH is still active (port 22 open)"
        echo "6. You can access via: ssh $NEW_USER@$TS_HOSTNAME"
    else
        echo "4. Tailscale has been connected with SSH enabled"
        echo "5. Traditional SSH (port 22) has been DISABLED"
        echo "6. You can ONLY access this server via: ssh $NEW_USER@$TS_HOSTNAME"
    fi
else
    echo "4. Tailscale setup incomplete - run 'tailscale up --ssh' manually"
    echo "5. Traditional SSH is still active on port 22"
fi
echo ""
if [ -n "$TEMP_PASS" ]; then
    echo ""
    print_warning "Temporary password for $NEW_USER: $TEMP_PASS"
    print_warning "You'll be forced to change this on first login!"
fi

echo ""
print_status "Setup log saved to: $LOGFILE"
echo ""
echo "==================================="
echo "Setup completed at: $(date)"
echo "===================================="
