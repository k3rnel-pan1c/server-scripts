#!/bin/bash


set -euo pipefail
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

NEW_USER="admin"

TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

print_status() {
    echo -e "${GREEN}[+]${NC} $1"
}

print_error() {
    echo -e "${RED}[!]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[*]${NC} $1"
}

if [[ $EUID -ne 0 ]]; then
   print_error "Script must be run as root"
   exit 1
fi

if id "$NEW_USER" &>/dev/null; then
    print_warning "User $NEW_USER already exists. Skipping user creation"
else
    print_status "Creating user $NEW_USER..."
    
    useradd -m -s /bin/bash "$NEW_USER"
    print_status "Setting temporary password for $NEW_USER..."
    
    TEMP_PASS=$(openssl rand -base64 12)
    
    echo "$NEW_USER:$TEMP_PASS" | chpasswd
    
    print_warning "Temporary password: $TEMP_PASS"
    print_warning "You'll need this for first login."
    
    passwd -e "$NEW_USER"
fi

print_status "Adding $NEW_USER to sudo group..."
usermod -aG sudo "$NEW_USER"
print_status "Configuring sudo permissions..."
echo "%sudo ALL=(ALL:ALL) ALL" > /etc/sudoers.d/sudo-group
chmod 440 /etc/sudoers.d/sudo-group

print_status "Setting up SSH directory for $NEW_USER"
USER_HOME="/home/$NEW_USER"
SSH_DIR="$USER_HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown -R "$NEW_USER:$NEW_USER" "$SSH_DIR"

if [ -f /root/.ssh/authorized_keys ]; then
    print_status "Copying SSH keys from root to $NEW_USER..."
    cp /root/.ssh/authorized_keys "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown "$NEW_USER:$NEW_USER" "$SSH_DIR/authorized_keys"
else
    print_warning "No SSH keys found you'll need to add them manually"
    touch "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    chown "$NEW_USER:$NEW_USER" "$SSH_DIR/authorized_keys"
fi

print_status "Configuring SSH ..."
SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

grep -q "^PermitRootLogin" "$SSHD_CONFIG" || echo "PermitRootLogin no" >> "$SSHD_CONFIG"
grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"

print_status "Testing SSH configuration..."
sshd -t
if [ $? -eq 0 ]; then
    print_status "SSH configuration is valid"
else
    print_error "SSH configuration test failed"
    rint_status" Restoring backup..."
    mv "$SSHD_CONFIG.bak.$(date +%Y%m%d_%H%M%S)" "$SSHD_CONFIG"
    exit 1
fi

print_status "Installing Tailscale..."
if [ -f /etc/debian_version ]; then
    # Debian/Ubuntu
    curl -fsSL https://tailscale.com/install.sh | sh
elif [ -f /etc/redhat-release ]; then
    # RHEL/CentOS/Fedora
    curl -fsSL https://tailscale.com/install.sh | sh
else
    print_error "Unsupported distro please instal Tailscale manually."
    exit 1
fi

print_status "Starting tailscale ..."
systemctl enable --now tailscaled
if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    print_status "Connecting to Tailnet..."
    tailscale up --authkey="$TAILSCALE_AUTH_KEY" --ssh
else
    print_warning "No Tailscale auth key provided. Run 'tailscale up' manually to connect"
fi

print_status "Locking root account.."
passwd -l root

print_status "Restarting SSH service..."
systemctl restart sshd

print_status "Setup complete!"
echo ""
print_warning "IMPORTANT:"
echo "1. the root account has been locked"
echo "2. SSH root login has been diabled"
echo "3. User '$NEW_USER' has been created with sudo privileges"
echo "4. A temporary password has been set you'll be forced to change it when first loging in"
echo ""
if [ -z "$TAILSCALE_AUTH_KEY" ]; then
    echo "6. Run 'tailscale up' to connect to your tailnet"
else
    echo "6. Tailscale has been connected to your Tailnet"
fi
echo ""
print_warning "Make sure you can SSH as $NEW_USER before closing this session"
print_warning "Test command: ssh $NEW_USER@<server-ip>"
