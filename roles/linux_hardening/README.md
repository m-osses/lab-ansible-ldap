# linux_hardening

Buenas prácticas de seguridad para los servidores Debian del lab. Se aplica a todo el grupo `linux` desde `playbooks/linux.yml`, **antes** de `linux_realm_join`, así que también cubre a los Linux que no se unen al dominio.

Probado contra Debian 13 (OpenSSH 10.0, fail2ban 1.1, nftables 1.1).

## Qué toca

| Archivo en el servidor | Contenido | Se aplica con |
|---|---|---|
| `/etc/ssh/sshd_config.d/05-hardening.conf` | Acceso, sesiones y algoritmos de SSH | `sshd -t && systemctl reload ssh` |
| `/etc/nftables.conf` | Firewall de entrada | `nft -f /etc/nftables.conf` |
| `/etc/fail2ban/jail.d/sshd.local` | Jail de SSH | reinicio de `fail2ban` |
| `/etc/sysctl.d/90-hardening.conf` | Parámetros de red y kernel | `sysctl --system` |
| `/etc/apt/apt.conf.d/20auto-upgrades` | Activa `unattended-upgrades` | timers de apt |

Paquetes: `fail2ban`, `python3-systemd`, `nftables`, `unattended-upgrades`.

Cada archivo se valida antes de instalarse (`sshd -t -f`, `nft -c -f`, `fail2ban-client --test`). Además, antes de recargar SSH se valida la configuración **completa**: un `sshd` roto deja a todos afuera.

## Variables

| Variable | Default | Dónde se cambia en este repo | Para qué |
|---|---|---|---|
| `ssh_allow_groups` | `[sysadmin]` | `group_vars/domain_members.yml` le suma `ad_linux_login_groups` | `AllowGroups` de sshd |
| `fail2ban_ignoreip` | `[]` | `group_vars/linux.yml`: `10.10.30.1` | IPs que nunca se banean (además de localhost) |
| `fail2ban_bantime` | `1h` | | Duración del primer baneo |
| `fail2ban_findtime` | `10m` | | Ventana en la que se cuentan los fallos |
| `fail2ban_maxretry` | `5` | | Fallos permitidos dentro de la ventana |
| `firewall_allowed_tcp_ports` | `[22]` | | Puertos TCP abiertos hacia el servidor |

Ejemplo, un Linux con un servidor web: en `inventory/host_vars/linux03.yml`, `firewall_allowed_tcp_ports: [22, 80, 443]`.

## Decisiones

### SSH

- **El orden de los archivos importa.** sshd usa el **primer** valor que encuentra para cada opción, y Debian incluye `sshd_config.d/*.conf` al principio de `sshd_config`. `05-hardening.conf` no repite ninguna opción de `10-ad.conf` (contraseña, keyboard-interactive y GSSAPI, que pone `linux_realm_join`), así que no compiten.
- **La contraseña sigue habilitada** porque los usuarios de AD no tienen clave SSH. `sysadmin` no tiene contraseña (cuenta bloqueada), así que sigue entrando solo con clave.
- **`AllowGroups`** es una segunda barrera además de `simple_allow_groups` de SSSD: si SSSD se configura mal, sshd igual rechaza a quien no esté en esos grupos. Incluye `sysadmin` (grupo primario del usuario de Ansible): **no quitarlo**.
- **`MaxAuthTries 3`**: cuenta cada clave que ofrece el cliente. Con muchas claves en el agente SSH, usar `-i ~/.ssh/homelab -o IdentitiesOnly=yes`.
- **Algoritmos**: solo intercambio de claves con curve25519 o híbridos post-cuánticos (`mlkem768x25519-sha256`, `sntrup761x25519`), cifrados AEAD (chacha20-poly1305, AES-GCM), MACs encrypt-then-MAC y claves ed25519/RSA-SHA2. Quedan afuera ECDSA NIST, SHA-1, CBC y CTR. Cualquier cliente OpenSSH de los últimos años es compatible.
- **Sin forwarding** (X11, agente, TCP, túneles): en el lab no se usan, y el reenvío del agente expone las claves del usuario al servidor.

### fail2ban

- **Lee de journald** (`backend = systemd`): Debian 13 no instala rsyslog, así que no existe `/var/log/auth.log`. Necesita `python3-systemd`.
- **`mode = aggressive`**: además de contraseñas fallidas, cuenta conexiones que se cortan sin autenticar y negociaciones fallidas de algoritmos (escaneos).
- **Baneo creciente**: `bantime.increment` duplica el tiempo con cada reincidencia, hasta 1 semana.
- **Banea con nftables** en su propia tabla (`f2b-table`), separada del firewall.
- **`10.10.30.1` está excluida.** Es el Proxmox, que hace SNAT de todo lo que entra por Tailscale: vista desde las VMs, cualquier conexión de afuera viene de esa IP. Si se baneara, nadie podría entrar, ni Ansible. El costo es que fail2ban solo protege frente a otras máquinas **dentro** de las redes del lab; el acceso de afuera lo controla Tailscale. Para que vea las IPs reales hay que desactivar el SNAT en el Proxmox (`tailscale set --snat-subnet-routes=false`). Las VMs ya devuelven el tráfico por el Proxmox, que es su gateway.

### Firewall

- Política `drop` en entrada: solo pasan loopback, conexiones ya establecidas, ICMP/ICMPv6 y los puertos de `firewall_allowed_tcp_ports`.
- Salida libre: SSSD, Kerberos, LDAP, DNS, NTP y apt inician las conexiones desde el servidor, y las respuestas entran como `established`.
- **Sin `flush ruleset`**: el archivo borra y recrea solo `table inet filter`. Recargar el firewall no borra los baneos de fail2ban.

### Kernel

| Parámetros | Para qué |
|---|---|
| `rp_filter`, `accept_redirects=0`, `send_redirects=0`, `accept_source_route=0`, `log_martians` | Descartar paquetes con origen falso o rutas impuestas desde afuera, y registrarlos |
| `tcp_syncookies`, `icmp_echo_ignore_broadcasts`, `icmp_ignore_bogus_error_responses` | Resistencia a SYN floods y a abusos de ICMP |
| `kptr_restrict=2`, `dmesg_restrict=1` | Ocultar direcciones del kernel y su log a usuarios sin privilegios (dificulta exploits) |
| `yama.ptrace_scope=1` | Un proceso solo puede depurar a sus hijos: un usuario no puede leer la memoria de otros procesos suyos (ej. robar el ticket de Kerberos de una sesión) |
| `unprivileged_bpf_disabled=1`, `bpf_jit_harden=2` | BPF solo para root; fuente habitual de escaladas de privilegios |
| `protected_hardlinks/symlinks/fifos/regular`, `suid_dumpable=0` | Ataques con enlaces y FIFOs en `/tmp`, y volcados de memoria de programas setuid |

### Actualizaciones

`unattended-upgrades` con la configuración de Debian (`50unattended-upgrades`): solo el repositorio de seguridad, todos los días, **sin reinicio automático**. Para ver si un parche de kernel necesita reinicio: `ls /var/run/reboot-required`.

## Verificar

Como `sysadmin`:

```bash
sudo sshd -T | grep -E 'permitrootlogin|allowgroups|maxauthtries|kexalgorithms|passwordauthentication'
sudo fail2ban-client status sshd
sudo nft list ruleset
sudo sysctl kernel.kptr_restrict net.ipv4.conf.all.rp_filter
systemctl list-timers 'apt-daily*'
```

Desde tu PC:

```bash
ssh root@10.10.30.21                       # rechazado: PermitRootLogin no
ssh carla.ruiz@10.10.30.21                 # rechazado: no está en AllowGroups
ssh -o KexAlgorithms=diffie-hellman-group14-sha1 sysadmin@10.10.30.21   # rechazado: algoritmo débil
nc -zv 10.10.30.21 80                      # timeout: el firewall descarta (no rechaza)
```

## Si algo sale mal

Si SSH queda inaccesible, entrar por la **consola de Proxmox** (`linux01 → Console`). `sysadmin` no tiene contraseña, así que la consola solo sirve si antes le pusiste una (`sudo passwd sysadmin`). Si no, apagar la VM y montar el disco desde el host, o recrearla con Terraform.

| Síntoma | Qué hacer |
|---|---|
| Ansible o tú no entran después de varios fallos | `sudo fail2ban-client set sshd unbanip <IP>`. Si la IP baneada es `10.10.30.1`, falta en `fail2ban_ignoreip` |
| Un usuario de dominio entra a SSSD pero sshd lo rechaza | No está en `ssh_allow_groups`: revisar `ad_linux_login_groups` |
| "Too many authentication failures" | El agente SSH ofrece demasiadas claves: `-o IdentitiesOnly=yes -i ~/.ssh/homelab` |
| "no matching key exchange method" | Cliente SSH muy viejo: actualizarlo |
| Un servicio nuevo no responde desde afuera | Agregar el puerto a `firewall_allowed_tcp_ports` |

Revertir a mano (por ejemplo, para diagnosticar):

```bash
sudo rm /etc/ssh/sshd_config.d/05-hardening.conf && sudo systemctl reload ssh
sudo nft delete table inet filter          # firewall abierto hasta el próximo arranque
sudo systemctl stop fail2ban
```

Volver a correr `linux.yml` deja todo como estaba.
