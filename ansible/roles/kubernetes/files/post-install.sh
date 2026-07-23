#!/bin/bash
# post-install.sh
# Created: 2025-11-03, dalthonmh
# Description:
# Automates the post-installation setup of a Kubernetes cluster. Designed to
# be executed on the master node, it performs the following:
# 1. Initializes the Kubernetes control plane (if not already initialized).
# 2. Configures kubectl for the master node user.
# 3. Installs the Calico network plugin for pod networking.
# 4. Connects worker nodes to the cluster using SSH.
# 5. Verifies the cluster status (nodes and pods).
#
# The script is idempotent: every step checks the current state first, so it
# can be re-run safely as many times as needed.
#
# Requirements:
# - Run this script as root or with sudo privileges.
# - Ensure "hosts.ini" is in the same directory (or point INVENTORY_FILE at it).
# - Worker nodes must be reachable over SSH without a password. This is set up
#   by roles/kubernetes/tasks/05_ssh_trust.yml.
#
# Usage:
#   Normally you do NOT run this by hand: the playbook copies it to /root and
#   executes it (roles/kubernetes/tasks/07_cluster_bootstrap.yml).
#
#     make up                # whole pipeline, from terraform to this script
#     make post-install      # replay only this step
#
#   Manual fallback, from the master node:
#     sudo ./post-install.sh

# Rollback when any command fails
set -euo pipefail

INVENTORY_FILE="${INVENTORY_FILE:-./hosts.ini}"
K8S_USER="root"
# Key created and distributed by roles/kubernetes/tasks/05_ssh_trust.yml. It must
# be passed explicitly: its name is not one of the identities SSH offers by
# default, so without -i every worker answers "Permission denied (publickey)".
SSH_KEY="${SSH_KEY:-/root/.ssh/id_ansible_master_debian}"
POD_CIDR="192.168.0.0/16"
# Pinned on purpose: the old "docs.projectcalico.org/manifests/calico.yaml"
# URL still serves Calico v3.25.0 (2023), which does not support Kubernetes 1.34.
CALICO_VERSION="v3.32.1"
CALICO_MANIFEST="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

# Real home of the target user ("/root" for root, not "/home/root")
HOME_DIR="$(getent passwd "$K8S_USER" | cut -d: -f6)"
KUBECONFIG_PATH="$HOME_DIR/.kube/config"

# Run kubectl always with the same kubeconfig, regardless of the invoking shell
kc() {
  sudo KUBECONFIG="$KUBECONFIG_PATH" kubectl "$@"
}

# Single entry point for every SSH call to a worker node
ssh_worker() {
  local NODE="$1"
  shift
  ssh -i "$SSH_KEY" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    "$K8S_USER@$NODE" "$@"
}

# Function to get worker node IPs from hosts.ini
get_workers() {
  awk '/\[workers\]/{flag=1; next} /^\[/{flag=0} flag && NF' "$INVENTORY_FILE" \
    | awk '{for (i=1; i<=NF; i++) if ($i ~ /^ansible_host=/) {split($i, a, "="); print a[2]}}'
}

# Function to get the master node IP from hosts.ini
get_master_ip() {
  awk '/\[master\]/{flag=1; next} /^\[/{flag=0} flag && NF' "$INVENTORY_FILE" \
    | awk '{for (i=1; i<=NF; i++) if ($i ~ /^ansible_host=/) {split($i, a, "="); print a[2]}}' \
    | head -n1
}

init_master() {
  if [ -f /etc/kubernetes/admin.conf ]; then
    echo "Kubernetes control plane is already initialized."
    return
  fi

  local MASTER_IP
  MASTER_IP="$(get_master_ip)"

  echo "Initializing Kubernetes control plane on the master node..."
  if [ -n "$MASTER_IP" ]; then
    # Pin the advertised API server address: on multi-NIC hosts (DigitalOcean
    # droplets have a private and a public interface) kubeadm may otherwise
    # pick the wrong IP and the cluster becomes unreachable.
    echo "Using API server advertise address: $MASTER_IP"
    sudo kubeadm init \
      --pod-network-cidr="$POD_CIDR" \
      --apiserver-advertise-address="$MASTER_IP" \
      --apiserver-cert-extra-sans="$MASTER_IP"
  else
    echo "WARNING: master IP not found in $INVENTORY_FILE, letting kubeadm autodetect."
    sudo kubeadm init --pod-network-cidr="$POD_CIDR"
  fi
}

setup_kubectl() {
  echo "Configuring kubectl for user $K8S_USER (home: $HOME_DIR)..."
  sudo mkdir -p "$HOME_DIR/.kube"
  # -f instead of -i: overwrite without prompting so re-runs never block
  sudo cp -f /etc/kubernetes/admin.conf "$KUBECONFIG_PATH"
  sudo chown "$K8S_USER":"$K8S_USER" "$HOME_DIR/.kube" "$KUBECONFIG_PATH"
  sudo chmod 600 "$KUBECONFIG_PATH"
  export KUBECONFIG="$KUBECONFIG_PATH"
}

wait_for_api() {
  echo "Waiting for the API server to be reachable..."
  for _ in $(seq 1 60); do
    if kc get --raw='/readyz' >/dev/null 2>&1; then
      echo "API server is ready."
      return 0
    fi
    sleep 5
  done
  echo "ERROR: API server did not become ready in time." >&2
  return 1
}

install_calico() {
  if kc get daemonset calico-node -n kube-system >/dev/null 2>&1; then
    echo "Calico is already installed."
    return
  fi
  echo "Installing Calico $CALICO_VERSION network plugin..."
  # Server-side apply: the Calico CRDs exceed the 256 KB annotation limit that
  # a client-side "kubectl apply" would hit ("metadata.annotations: Too long").
  kc apply --server-side --force-conflicts -f "$CALICO_MANIFEST"
}

get_join_command() {
  sudo kubeadm token create --print-join-command
}

# A worker is considered joined when it already has a kubelet kubeconfig
worker_is_joined() {
  local NODE="$1"
  ssh_worker "$NODE" "test -f /etc/kubernetes/kubelet.conf" >/dev/null 2>&1
}

join_workers() {
  local WORKERS
  WORKERS="$(get_workers)"

  if [ -z "$WORKERS" ]; then
    echo "No worker nodes found in $INVENTORY_FILE."
    return
  fi

  local JOIN_CMD=""
  for NODE in $WORKERS; do
    if worker_is_joined "$NODE"; then
      echo "Worker node $NODE is already part of the cluster, skipping."
      continue
    fi

    # Only mint a token when there is actually a node to join (tokens expire)
    if [ -z "$JOIN_CMD" ]; then
      JOIN_CMD="$(get_join_command)"
      echo "Join command: $JOIN_CMD"
    fi

    echo "Connecting worker node $NODE to the cluster..."
    ssh_worker "$NODE" "sudo $JOIN_CMD"
  done
}

check_cluster() {
  echo "Checking cluster status..."
  kc get nodes -o wide
  kc get pods -A
}

# Main script execution
main() {
  echo "=========================="
  echo "   Kubernetes Post Setup  "
  echo "=========================="

  init_master
  setup_kubectl
  wait_for_api
  install_calico
  join_workers
  check_cluster

  echo "Cluster setup completed successfully."
}

main
