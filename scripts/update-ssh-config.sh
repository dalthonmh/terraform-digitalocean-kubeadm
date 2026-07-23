#!/usr/bin/env bash
#
# Sincroniza ~/.ssh/config con las IPs actuales de los droplets de este
# proyecto. Ejecutar despues de "terraform apply".
#
#   ./scripts/update-ssh-config.sh            # usa terraform output
#   ./scripts/update-ssh-config.sh --dry-run  # muestra el bloque, no escribe
#
# El bloque gestionado vive entre los marcadores BEGIN/END de abajo. Todo lo
# que este fuera de ellos no se toca.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INVENTORY="${PROJECT_DIR}/ansible/hosts.ini"

SSH_CONFIG="${SSH_CONFIG:-$HOME/.ssh/config}"
SSH_KEY="${SSH_KEY:-~/.ssh/id_digitalocean_kubeadm}"
SSH_USER="${SSH_USER:-root}"

BEGIN_MARK="# >>> terraform-digitalocean-kubeadm >>>"
END_MARK="# <<< terraform-digitalocean-kubeadm <<<"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

# --- 1. Obtener las IPs -----------------------------------------------------
# Fuente primaria: el state de Terraform. Fallback: el inventario de Ansible,
# util si se corre en una maquina sin credenciales de DigitalOcean.
# "terraform output -raw" imprime avisos por stdout y sale con codigo 0 cuando
# el state esta vacio, asi que el valor se valida como IPv4 antes de aceptarlo.
is_ipv4() {
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

get_ips_from_terraform() {
  command -v terraform >/dev/null 2>&1 || return 1
  CP01_IP="$(terraform -chdir="$PROJECT_DIR" output -raw cp01_ip 2>/dev/null)" || return 1
  WK01_IP="$(terraform -chdir="$PROJECT_DIR" output -raw wk01_ip 2>/dev/null)" || return 1
  is_ipv4 "$CP01_IP" && is_ipv4 "$WK01_IP"
}

get_ips_from_inventory() {
  [[ -f "$INVENTORY" ]] || return 1
  CP01_IP="$(sed -n 's/^cp01 .*ansible_host=\([0-9.]*\).*/\1/p' "$INVENTORY")"
  WK01_IP="$(sed -n 's/^wk01 .*ansible_host=\([0-9.]*\).*/\1/p' "$INVENTORY")"
  is_ipv4 "$CP01_IP" && is_ipv4 "$WK01_IP"
}

if get_ips_from_terraform; then
  echo "IPs leidas de: terraform output"
elif get_ips_from_inventory; then
  echo "IPs leidas de: $INVENTORY"
else
  echo "ERROR: no pude obtener las IPs. Corre 'terraform apply' primero." >&2
  exit 1
fi

echo "  cp01 = $CP01_IP"
echo "  wk01 = $WK01_IP"

# --- 2. Construir el bloque -------------------------------------------------
BLOCK="$(cat <<EOT
${BEGIN_MARK}
# Generado por scripts/update-ssh-config.sh - no editar a mano.
Host cp01 ${CP01_IP}
    HostName ${CP01_IP}
    User ${SSH_USER}
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new

Host wk01 ${WK01_IP}
    HostName ${WK01_IP}
    User ${SSH_USER}
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
${END_MARK}
EOT
)"

if [[ $DRY_RUN -eq 1 ]]; then
  printf '%s\n' "$BLOCK"
  exit 0
fi

# --- 3. Reescribir el bloque en ~/.ssh/config -------------------------------
mkdir -p "$(dirname "$SSH_CONFIG")"
touch "$SSH_CONFIG"

BACKUP="${SSH_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
cp "$SSH_CONFIG" "$BACKUP"
echo "Backup: $BACKUP"

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

# sed borra el bloque anterior (rango entre marcadores, inclusive).
sed "/^${BEGIN_MARK}$/,/^${END_MARK}$/d" "$SSH_CONFIG" > "$TMP"

# Quitar lineas en blanco sobrantes al final y anexar el bloque nuevo.
printf '%s\n\n%s\n' "$(sed -e :a -e '/^\s*$/{$d;N;ba' -e '}' "$TMP")" "$BLOCK" > "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# --- 4. Limpiar known_hosts de IPs recicladas -------------------------------
if [[ -f "$HOME/.ssh/known_hosts" ]]; then
  ssh-keygen -R "$CP01_IP" >/dev/null 2>&1 || true
  ssh-keygen -R "$WK01_IP" >/dev/null 2>&1 || true
fi

echo "OK. ~/.ssh/config actualizado. Prueba: ssh cp01"
