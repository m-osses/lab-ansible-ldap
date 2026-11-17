#!/usr/bin/env bash
# Lee las contraseñas de terraform output y las guarda cifradas con ansible-vault
# en inventory/group_vars/all/vault.yml. Volver a correrlo después de recrear el lab.
#
# Uso: scripts/terraform-secrets.sh [ruta al repo de Terraform]
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
tf_dir="${1:-$repo/../terraform-homeserver-lab}"
vault_file="$repo/inventory/group_vars/all/vault.yml"
vault_pass="$repo/.vault_pass"

if [[ ! -d "$tf_dir" ]]; then
    echo "No existe el repo de Terraform: $tf_dir" >&2
    exit 1
fi

tf() { terraform -chdir="$tf_dir" output -raw "$1"; }

admin="$(tf windows_admin_password)"
dsrm="$(tf ad_safe_mode_password)"
users="$(tf ad_users_initial_password)"

# Contraseña del vault: se genera una vez y se queda local
if [[ ! -f "$vault_pass" ]]; then
    (umask 077 && openssl rand -base64 32 > "$vault_pass")
    echo "Creada $vault_pass (guárdala: sin ella no se descifra vault.yml)"
fi

# Las contraseñas de Terraform son solo letras y números: no hace falta escaparlas
plain="$(mktemp)"
trap 'rm -f "$plain"' EXIT
cat > "$plain" <<EOF
---
# Generado por scripts/terraform-secrets.sh desde terraform output
vault_windows_admin_password: "$admin"
vault_ad_safe_mode_password: "$dsrm"
vault_ad_users_initial_password: "$users"
EOF

ansible-vault encrypt --vault-password-file "$vault_pass" --output "$vault_file" "$plain"
echo "Actualizado $vault_file"
