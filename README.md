# lab-ansible-ldap

Configuración con Ansible del lab de Active Directory que crea [terraform-homeserver-lab](../terraform-homeserver-lab):

| Playbook | Hosts | Conexión | Qué hace |
|---|---|---|---|
| `playbooks/ad.yml` | dc01, dc02 | WinRM (NTLM) | Bosque `lab.internal`, promoción de dc02, DNS/hora, OUs, grupos y usuarios |
| `playbooks/linux.yml` | linux01, linux02 | SSH (`sysadmin`) | Hardening (SSH, fail2ban, firewall, kernel, updates) y `realm join` con realmd + SSSD, login SSH y sudo para grupos de AD |
| `playbooks/site.yml` | todos | | Los dos en orden |

## Estructura

```
├── ansible.cfg
├── requirements.yml                  # collections: ansible.windows, microsoft.ad, community.general
├── inventory/
│   ├── hosts.yml                     # windows/dcs/{dc_primary,dc_replicas}, linux/domain_members
│   └── group_vars/
│       ├── all/main.yml              # dominio, IPs de los DCs, alias de las contraseñas
│       ├── all/vault.yml             # contraseñas cifradas (lo genera el script)
│       ├── windows.yml               # conexión WinRM
│       ├── linux.yml                 # conexión SSH, IPs que fail2ban no banea
│       ├── dcs/dns.yml               # reenviadores DNS y NTP del PDC
│       ├── dcs/objects.yml           # OUs, grupos y usuarios del dominio
│       └── domain_members.yml        # OU de equipos, grupos con login, sudo y AllowGroups de SSH
├── roles/
│   ├── windows_hostname/             # nombre del inventario (dc01, dc02) si Cloudbase-Init no lo puso
│   ├── ad_forest/                    # crea el bosque (dc_primary)
│   ├── ad_dc_promote/                # DCs adicionales (dc_replicas)
│   ├── ad_dc_dns/                    # DNS cruzado, reenviadores y hora
│   ├── ad_objects/                   # OUs, grupos, usuarios
│   ├── linux_hardening/              # todos los Linux: SSH, fail2ban, nftables, sysctl, updates
│   └── linux_realm_join/             # join, SSSD, Kerberos, chrony, sudo, sshd
├── playbooks/  ad.yml, linux.yml, site.yml
└── scripts/terraform-secrets.sh      # terraform output -> vault.yml
```

Los grupos del inventario separan por **sistema** (`windows`, `linux`: cómo conectarse) y por **función** (`dcs`, `domain_members`: qué se configura). Un Linux nuevo que no tenga que unirse al dominio va en `linux`, pero fuera de `domain_members`.

## Antes de empezar: requisitos en tu PC

Todo esto se hace una sola vez en la máquina desde la que corres Ansible.

### 1. Ansible y herramientas

```bash
sudo pacman -S ansible terraform openssl openssh
```

- `ansible`: trae `ansible-core` y las collections de la comunidad.
- `terraform`: el script de secretos lo usa para leer `terraform output`.
- `openssl`: el script lo usa para generar `.vault_pass`.

### 2. WinRM: pywinrm

Ansible no habla WinRM por sí solo: necesita la librería **pywinrm**, que trae NTLM (`requests-ntlm` / `pyspnego`). Tiene que estar instalada en el **mismo Python que usa Ansible**:

```bash
ansible --version | grep "python version"     # qué Python usa Ansible
```

| Cómo instalaste Ansible | Cómo instalar pywinrm |
|---|---|
| `pacman` (paquete del sistema) | `sudo pacman -S python-pywinrm` |
| `pipx` | `pipx inject ansible-core pywinrm` (o `pipx inject ansible pywinrm`) |
| virtualenv | `pip install pywinrm` con el venv activado |

En Arch, `pip install` sobre el Python del sistema está bloqueado (PEP 668): usa una de las opciones de la tabla.

Probar que quedó bien:

```bash
python -c "import winrm; print('pywinrm ok')"   # con el Python que mostró ansible --version
```

### 3. Collections de Ansible

```bash
ansible-galaxy collection install -r requirements.yml
```

Instala `ansible.windows` y `microsoft.ad` (módulos de Windows y AD) y `community.general` (`ini_file` para SSSD). Si ya vienen con el paquete `ansible`, solo comprueba las versiones.

### 4. Clave SSH del homelab

La misma del paso 0 del repo de Terraform: Terraform carga la pública en los Linux y Ansible entra con la privada (`ansible_ssh_private_key_file` en `inventory/group_vars/linux.yml`).

```bash
ssh-keygen -t ed25519 -f ~/.ssh/homelab -C "homelab"   # si no existe
eval "$(ssh-agent -s)" && ssh-add ~/.ssh/homelab       # si le pusiste passphrase
```

### 5. Acceso a la red del lab

Tu PC tiene que llegar a `10.10.30.0/24` (paso 5 del repo de Terraform):

```bash
sudo tailscale set --accept-routes
ping 10.10.30.11
```

Puertos que se usan: **5985/TCP** (WinRM HTTP) hacia los DCs y **22/TCP** (SSH) hacia los Linux.

### Comprobación rápida

Con las VMs creadas y `scripts/terraform-secrets.sh` ya corrido:

```bash
ansible windows -m ansible.windows.win_ping     # WinRM + NTLM + contraseña OK
ansible linux -m ping                           # SSH + clave OK
```

## Secretos

Las contraseñas las genera Terraform. El script las copia a `inventory/group_vars/all/vault.yml`, cifradas con ansible-vault:

```bash
scripts/terraform-secrets.sh                 # por defecto lee ../terraform-homeserver-lab
scripts/terraform-secrets.sh /otra/ruta      # o el repo de Terraform que indiques
```

- La primera vez crea `.vault_pass` (la contraseña del vault, no se sube al repo). `ansible.cfg` la usa sola.
- Al destruir y recrear el lab Terraform genera contraseñas nuevas: hay que volver a correr el script.
- Ver el contenido: `ansible-vault view inventory/group_vars/all/vault.yml`.

| Variable | Origen | Uso |
|---|---|---|
| `windows_admin_password` | `windows_admin_password` | WinRM, unir dc02 y los Linux al dominio |
| `ad_safe_mode_password` | `ad_safe_mode_password` | DSRM al crear el bosque y promover DCs |
| `ad_users_initial_password` | `ad_users_initial_password` | Contraseña inicial de los usuarios de `objects.yml` |

## Paso a paso

Encaja con los pasos del repo de Terraform:

```bash
# 1. Terraform: ad_deploy_vms = true -> crea dc01 y dc02
scripts/terraform-secrets.sh
ansible windows -m ansible.windows.win_ping        # probar WinRM

# 2. Dominio (tarda: crear el bosque y promover dc02 reinician los DCs)
ansible-playbook playbooks/ad.yml

# 3. Terraform: linux_deploy_vms = true -> crea linux01 y linux02 (usan los DCs como DNS)
ansible linux -m ping                               # probar SSH

# 4. Join de los Linux
ansible-playbook playbooks/linux.yml
```

Con todo creado, `ansible-playbook playbooks/site.yml` aplica todo. Los playbooks son idempotentes: se pueden volver a correr.

Para uno solo: `ansible-playbook playbooks/linux.yml --limit linux01`.

## Qué configura cada parte

### Dominio (`ad.yml`)

0. **Los dos DCs**: si el hostname no es el del inventario (`dc01`, `dc02`), lo cambia y reinicia. Si el servidor ya es DC con otro nombre, falla y no lo toca: renombrar un DC rompe DNS y SPNs.
1. **dc01**: instala AD DS y crea el bosque `lab.internal` (NetBIOS `LAB`) con DNS integrado. Reinicia.
2. **dc02**: usa dc01 como DNS, se promueve como DC adicional (con DNS). Reinicia.
3. **Los dos DCs**: DNS del cliente apuntando al otro DC y después a sí mismo, reenviadores `1.1.1.1` y `9.9.9.9`. El que tiene el rol PDC toma la hora de `pool.ntp.org`.
4. **Objetos** (en dc01, AD los replica):

```
DC=lab,DC=internal
└── OU=Lab
    ├── OU=Users     ana.garcia (linux-admins), bruno.diaz (linux-users), carla.ruiz
    ├── OU=Groups    linux-users, linux-admins
    └── OU=Servers   cuentas de equipo de los Linux
```

Para agregar usuarios o grupos se edita `inventory/group_vars/dcs/objects.yml` y se vuelve a correr `ad.yml`. La contraseña de un usuario solo se fija al crearlo; las corridas siguientes no la pisan.

### Seguridad de los Linux (`linux.yml`, rol `linux_hardening`)

Se aplica a **todos** los Linux (grupo `linux`), estén o no en el dominio, antes del join. El detalle (variables, por qué cada valor, cómo verificar y revertir) está en [roles/linux_hardening/README.md](roles/linux_hardening/README.md).

| Qué | Cómo |
|---|---|
| **SSH** (`/etc/ssh/sshd_config.d/05-hardening.conf`) | Sin login de root, `AllowGroups` (solo `sysadmin` y los grupos de AD con login), `MaxAuthTries 3`, sesiones inactivas cortadas a los 10 min, sin X11/agent/TCP forwarding, `LogLevel VERBOSE`, solo algoritmos modernos (incluye `mlkem768x25519`, post-cuántico) |
| **fail2ban** | Jail `sshd` en modo `aggressive`, leyendo de journald. 5 fallos en 10 min → baneo de 1 h, que se duplica con cada reincidencia (máx. 1 semana). Banea con nftables |
| **Firewall** (nftables) | Entrante: todo descartado salvo SSH (22), ICMP y conexiones ya establecidas. Saliente libre (DNS, Kerberos, LDAP, NTP hacia los DCs) |
| **Kernel** (`/etc/sysctl.d/90-hardening.conf`) | Sin redirecciones ICMP ni source routing, `rp_filter`, SYN cookies, `kptr_restrict`, `dmesg_restrict`, `ptrace_scope`, BPF restringido, protección de enlaces en `/tmp` |
| **Actualizaciones** | `unattended-upgrades` diario, solo de seguridad y sin reinicio automático |

**Ojo con fail2ban y Tailscale:** las conexiones desde fuera del lab llegan con la IP del Proxmox (`10.10.30.1`), porque hace SNAT del tráfico de Tailscale. Esa IP está en `fail2ban_ignoreip` (`group_vars/linux.yml`): si se baneara, nadie podría entrar, ni Ansible. Por eso fail2ban solo frena ataques desde **dentro** de las redes del lab (otra VM comprometida). El acceso desde fuera lo controla Tailscale. Para que fail2ban vea la IP real de Tailscale habría que desactivar el SNAT en el Proxmox (`tailscale set --snat-subnet-routes=false`).

Comandos útiles (como `sysadmin`, con `sudo`):

```bash
fail2ban-client status sshd                    # IPs baneadas y fallos recientes
fail2ban-client set sshd unbanip 10.10.30.50   # desbanear
nft list ruleset                               # firewall + tabla de fail2ban
sshd -T | grep -E 'allowgroups|kexalgorithms'  # configuración efectiva de SSH
```

Para abrir otro puerto, agregarlo a `firewall_allowed_tcp_ports` (por grupo o por host) y volver a correr `linux.yml`.

### Linux en el dominio (`linux.yml`, rol `linux_realm_join`)

- Instala realmd, SSSD, adcli, Kerberos, chrony y qemu-guest-agent.
- chrony sincroniza con los DCs (Kerberos falla con más de 5 minutos de diferencia).
- `realm join` en `OU=Servers,OU=Lab` con la cuenta Administrator.
- SSSD: nombres cortos (`ana.garcia`, sin `@lab.internal`), home `/home/<usuario>` creado en el primer login y **solo pueden entrar** `linux-users` y `linux-admins`.
- `linux-admins` tiene sudo (pide la contraseña del dominio).
- sshd acepta contraseña y Kerberos (GSSAPI). `sysadmin` no tiene contraseña: sigue entrando solo con la clave.

## Probar

```bash
ssh ana.garcia@10.10.30.21        # contraseña: ad_users_initial_password
id                                # grupos de AD: linux-admins, domain users...
sudo -l
ssh carla.ruiz@10.10.30.21        # rechazado: no está en ningún grupo con acceso
```

En el Linux, como `sysadmin`: `realm list`, `getent passwd ana.garcia`, `sssctl domain-status lab.internal`.

## Problemas conocidos / a verificar

Este código **no se probó todavía contra el lab**.

| Síntoma | Causa probable |
|---|---|
| `win_ping` falla con error de autenticación | `vault.yml` desactualizado tras recrear el lab: volver a correr el script |
| `ntlm: auth method ntlm requires a password` / módulo `winrm` no encontrado | Falta pywinrm en el Python que usa Ansible |
| Falla "mismo SID de máquina que el dominio", o la promoción de dc02 da "The user name or password is incorrect" | La plantilla de Packer no se generalizó con sysprep: todos los clones comparten SID (y hostname). Reconstruir la plantilla y recrear los DCs |
| La promoción de dc02 no encuentra el dominio | dc01 todavía no terminó de arrancar los servicios de AD tras el reinicio: esperar y repetir |
| `realm join` falla con "Couldn't connect to domain" | Los Linux no resuelven `lab.internal`: revisar `/etc/resolv.conf` (tienen que ser los DCs) |
| `realm join` falla con error de Kerberos o de reloj | Hora desincronizada: `chronyc sources` en el Linux, `w32tm /query /status` en el DC |
| El usuario de dominio entra pero no tiene home | `pam_mkhomedir` no se habilitó: revisar `/etc/pam.d/common-session` |

**Seguridad:** el join usa la cuenta Administrator por simplicidad. En algo que no sea un lab conviene una cuenta dedicada con permiso delegado solo para crear equipos en `OU=Servers`.
