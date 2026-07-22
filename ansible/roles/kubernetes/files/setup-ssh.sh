#!/bin/bash
# setup-ssh.sh
# Created: 2025-11-04, dalthonmh
# Description:
# This script sets up SSH key-based access from the master node to worker nodes
# in a Kubernetes cluster. It generates an SSH key (if missing), copies it to
# the worker nodes, and configures the SSH client for seamless access.

# Requirements:
# - Run this script as the "superadmin" user (do NOT use sudo).
# - Ensure the "hosts.ini" file is in the same directory as this script.

# Notes:
# - You will be prompted to confirm the SSH connection:
#   "Are you sure you want to continue connecting (yes/no/[fingerprint])?": yes
# - Enter the "superadmin" password for each worker node when prompted.

# Usage:
#   ./setup-ssh.sh

# Variables
SSH_KEY_NAME="id_ansible_master_debian"
SSH_DIR="$HOME/.ssh"
INVENTORY_FILE="./hosts.ini"
USER="superadmin"

# Get worker node IPs from hosts.ini
get_workers() {
  awk '/\[workers\]/{flag=1; next} /\[/{flag=0} flag && NF' "$INVENTORY_FILE" | awk '{print $2}' | awk -F'=' '{print $2}'
}

# Create SSH key if it does not exist
if [ ! -f "$SSH_DIR/$SSH_KEY_NAME" ]; then
  echo "Generating SSH key..."
  ssh-keygen -t ed25519 -C "ansible@master" -f "$SSH_DIR/$SSH_KEY_NAME" -N ""
else
  echo "SSH key already exists: $SSH_DIR/$SSH_KEY_NAME"
fi

# Copy SSH public key to worker nodes
WORKERS=$(get_workers)
for WORKER in $WORKERS; do
  echo "Copying SSH key to $WORKER..."
  ssh-copy-id -i "$SSH_DIR/$SSH_KEY_NAME.pub" "$USER@$WORKER"
done

# Configure the ~/.ssh/config file
SSH_CONFIG="$SSH_DIR/config"
if ! grep -q "Host 192.168.0." "$SSH_CONFIG"; then
  echo "Configuring SSH config file..."
  for WORKER in $WORKERS; do
    cat <<EOF >> "$SSH_CONFIG"
Host $WORKER
    User $USER
    IdentityFile $SSH_DIR/$SSH_KEY_NAME
    IdentitiesOnly yes
EOF
  done
else
  echo "SSH config already contains worker nodes."
fi

echo "SSH configuration completed!"
