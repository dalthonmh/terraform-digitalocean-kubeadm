# Makefile - terraform-digitalocean-kubeadm
#
# Full pipeline: droplets on DigitalOcean (Terraform) -> local SSH config ->
# node setup and cluster bootstrap (Ansible).
#
#   make up        # everything, end to end
#   make help      # list every target
#
# Requires: terraform, ansible, ssh. Credentials in terraform.tfvars
# (do_token) and the private key ~/.ssh/id_digitalocean_kubeadm.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT_DIR   := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ANSIBLE_DIR   := $(PROJECT_DIR)/ansible
PLAYBOOK      := kube-play.yml
INVENTORY     := $(ANSIBLE_DIR)/hosts.ini
SSH_KEY       ?= ~/.ssh/id_digitalocean_kubeadm

# Extra flags, e.g.: make play ANSIBLE_FLAGS="-vv"
TF_FLAGS      ?=
ANSIBLE_FLAGS ?=

.PHONY: help init fmt validate plan apply ssh-config inventory check-inventory \
        ping play post-install up status kubeconfig ssh-cp01 ssh-wk01 destroy \
        destroy-force clean

## help: list the available targets
help:
	@echo "terraform-digitalocean-kubeadm"
	@echo
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  make /'
	@echo
	@echo "Variables: TF_FLAGS, ANSIBLE_FLAGS, SSH_KEY"

# --- Terraform --------------------------------------------------------------

## init: terraform init
init:
	terraform -chdir=$(PROJECT_DIR) init

## fmt: format the .tf files
fmt:
	terraform -chdir=$(PROJECT_DIR) fmt -recursive

## validate: validate the Terraform configuration
validate:
	terraform -chdir=$(PROJECT_DIR) validate

## plan: show the plan without applying it
plan:
	terraform -chdir=$(PROJECT_DIR) plan $(TF_FLAGS)

## apply: create/update the droplets and regenerate ansible/hosts.ini
apply:
	terraform -chdir=$(PROJECT_DIR) apply -auto-approve $(TF_FLAGS)

# --- Local wiring -----------------------------------------------------------

## ssh-config: sync ~/.ssh/config with the current droplet IPs
ssh-config:
	SSH_KEY=$(SSH_KEY) $(PROJECT_DIR)/scripts/update-ssh-config.sh

## inventory: show the generated inventory
inventory: check-inventory
	@cat $(INVENTORY)

# Guard: every Ansible target needs the inventory Terraform writes. Checked in
# a recipe (not as a file prerequisite) so it also works inside "make up",
# where "apply" creates the file during the same run.
check-inventory:
	@test -f $(INVENTORY) || { \
		echo "ERROR: $(INVENTORY) missing. Run 'make apply' first." >&2; exit 1; }

# --- Ansible ----------------------------------------------------------------

## ping: check that Ansible reaches every node
ping: check-inventory
	cd $(ANSIBLE_DIR) && ansible all -m ping $(ANSIBLE_FLAGS)

## play: full playbook (prereqs, containerd, k8s, SSH trust, bootstrap)
play: check-inventory
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOK) $(ANSIBLE_FLAGS)

## post-install: re-run only the cluster bootstrap (post-install.sh)
# copy-master is included so a locally edited script reaches the node.
post-install: check-inventory
	cd $(ANSIBLE_DIR) && ansible-playbook $(PLAYBOOK) -t copy-master,bootstrap $(ANSIBLE_FLAGS)

# --- Pipeline ---------------------------------------------------------------

## up: apply + ssh-config + play (whole cluster from scratch)
up: apply ssh-config play status

# --- Operations -------------------------------------------------------------

## status: nodes and pods as seen from the master
status:
	@ssh -F ~/.ssh/config cp01 'kubectl --kubeconfig /root/.kube/config get nodes -o wide && \
		kubectl --kubeconfig /root/.kube/config get pods -A'

## kubeconfig: copy the master kubeconfig to ~/.kube/config-kubeadm-do
kubeconfig:
	@set -euo pipefail; \
	CP_IP="$$(terraform -chdir=$(PROJECT_DIR) output -raw cp01_ip)"; \
	DEST="$$HOME/.kube/config-kubeadm-do"; \
	mkdir -p "$$HOME/.kube"; \
	ssh -F ~/.ssh/config cp01 'cat /root/.kube/config' > "$$DEST"; \
	sed -i.bak "s#server: https://.*:6443#server: https://$$CP_IP:6443#" "$$DEST"; \
	rm -f "$$DEST.bak"; chmod 600 "$$DEST"; \
	echo "OK: $$DEST"; \
	echo "Use it with: export KUBECONFIG=$$DEST"

## ssh-cp01: shell on the master node
ssh-cp01:
	ssh -F ~/.ssh/config cp01

## ssh-wk01: shell on the worker node
ssh-wk01:
	ssh -F ~/.ssh/config wk01

# --- Teardown ---------------------------------------------------------------

## destroy: destroy the droplets (Terraform asks for confirmation)
destroy:
	terraform -chdir=$(PROJECT_DIR) destroy $(TF_FLAGS)

## destroy-force: destroy without confirmation - deletes the whole cluster
destroy-force:
	terraform -chdir=$(PROJECT_DIR) destroy -auto-approve $(TF_FLAGS)

## clean: remove local Ansible leftovers (log, .retry)
clean:
	rm -f $(ANSIBLE_DIR)/ansible.log $(ANSIBLE_DIR)/*.retry
	@echo "Clean."
