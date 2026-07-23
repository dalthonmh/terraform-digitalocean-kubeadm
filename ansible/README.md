# Kubernetes Cluster Configuration

This document describes the steps required to configure a Kubernetes cluster using Ansible and Debian virtual machines.

## 1. Installing Ansible

We will install Ansible on our machine to manage the virtual machines.

- On macOS:

```bash
brew install ansible
ansible --version
```

> Note: Ensure that the Debian servers have Python installed and the SSH service enabled.

This will assign names to the IP addresses of the nodes, making them easier to identify.

## 3. Configure SSH Access

To allow Ansible to manage the nodes, we will configure passwordless SSH access from the control node (MacBook).

### 3.1. Generate an SSH Key:

```bash
cd ~/.ssh
ssh-keygen -t ed25519 -C "ansible@mac"
```

> Note: When prompted for a name for the key, you can use something like `id_digitalocean_kubeadm`.

### 3.2. Copy the Public Key to the Debian Nodes

```bash
ssh-copy-id -i ~/.ssh/id_digitalocean_kubeadm.pub root@104.131.161.196
ssh-copy-id -i ~/.ssh/id_digitalocean_kubeadm.pub root@68.183.52.56
```

This will allow the host (MacBook) to connect to the nodes without needing to enter a password.

## 4. Configuring the ~/.ssh/config File

If you have multiple SSH keys on the MacBook, you can configure the `~/.ssh/config` file so that Ansible automatically uses the correct key when connecting to each node. Use the IPs from `hosts.ini`.

### 4.1. Open the SSH Configuration File:

```bash
vim ~/.ssh/config
```

### 4.2. Add the Following Configurations for Each Node:

```bash
# k8s-master node (cp01)

Host 104.131.161.196
User root
IdentityFile ~/.ssh/id_digitalocean_kubeadm
IdentitiesOnly yes

# k8s-worker1 node (wk01)

Host 68.183.52.56
User root
IdentityFile ~/.ssh/id_digitalocean_kubeadm
IdentitiesOnly yes
```

## 5. Basic Ansible Commands

Test the connection with the VMs:

```bash
ansible -i hosts.ini all -m ping
```

Run the playbook:

```bash
ansible-playbook -i hosts.ini kube-play.yml
```

The playbook installs containerd, the Kubernetes binaries and the shell settings, sets up passwordless SSH from the master node to the workers, and copies `post-install.sh` plus `hosts.ini` to `/root/` on the master. **It does not create the cluster** — that is the next step.

## 6. Post-Installation: Create the Cluster

Once the playbook finishes, connect to the master node and run the script:

```bash
ssh root@<master-ip>
cd /root && ./post-install.sh
```

`post-install.sh` runs `kubeadm init`, configures `kubectl` for `root`, installs Calico, and joins every worker listed in `hosts.ini`.

The script is idempotent: it checks the state of each step before acting, so you can re-run it as many times as you need (for example, after adding a new worker to `hosts.ini`).

### Troubleshooting

**`Permission denied (publickey)` when the script joins a worker**

The master node lost its SSH trust with the workers. Re-run just that part of the playbook from your machine:

```bash
ansible-playbook kube-play.yml --tags ssh-trust
```

Then verify from the master node:

```bash
ssh -o BatchMode=yes root@<worker-ip> hostname
```

This trust cannot be created from the master itself: cloud images ship with `PasswordAuthentication no`, so `ssh-copy-id` has no way to authenticate. Ansible pushes the key from the control machine instead.

**The API server is unreachable / wrong cluster IP**

`post-install.sh` pins `--apiserver-advertise-address` to the master IP found in `hosts.ini`. Make sure that IP is the current one after a `terraform apply` — droplets get a new address every time they are recreated.
