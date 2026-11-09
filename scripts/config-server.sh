#!/usr/bin/env bash
# =============================================================================
#  config-server.sh
#  Provisionamento automatizado de servidores de produção (Oracle Cloud / Ubuntu 22+)
#
#  Passos executados:
#    1) Fail2Ban para SSH
#    2) Swap 8GB + earlyoom
#    3) Docker + tuning de kernel, limites e rede
#    4) Auto-montagem de Block Storage anexado (interativo)
#    5) Script de monitoramento de disco + cron (Uptime Kuma)
#
#  Uso:
#    sudo ./config-server.sh [opções]
#
#  Opções:
#    --only 1,3             Executa apenas os passos listados
#    --skip 4,5             Pula os passos listados
#    --kuma-url <URL>       URL de push do Uptime Kuma (passo 5)
#    --monitor-path <path>  Ponto de montagem monitorado pelo disk-check (passo 5)
#    --no-mount             Pula o passo 4 (montagem de discos)
#    --yes                  Auto-confirma prompts onde for seguro
#    -h, --help             Mostra esta ajuda
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configurações fixas
# -----------------------------------------------------------------------------
SWAP_SIZE="8G"

FAIL2BAN_IGNOREIP="127.0.0.1/8 ::1 10.0.0.0/24"
FAIL2BAN_BANTIME="10m"
FAIL2BAN_MAXRETRY=5

LOKI_DRIVER_VERSION="3.3.2"
DOCKER_GWBRIDGE_SUBNET="172.18.0.0/16"
DOCKER_MTU=8400

MARKER_BEGIN="# >>> config-server.sh (managed) >>>"
MARKER_END="# <<< config-server.sh (managed) <<<"

# -----------------------------------------------------------------------------
# Variáveis de runtime
# -----------------------------------------------------------------------------
STEPS_AVAILABLE=(1 2 3 4 5)
STEPS_TO_RUN=()
SKIP_STEPS=()
ONLY_STEPS=()
KUMA_URL=""
MONITOR_PATH=""
NO_MOUNT=0
AUTO_YES=0
ARCH=""
LOG_FILE=""

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

# =============================================================================
# Funções utilitárias
# =============================================================================

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()      { printf '%s[%s]%s %s\n' "$BLUE"   "$(_ts)" "$RESET" "$*" | tee -a "$LOG_FILE"; }
log_ok()   { printf '%s[%s] ✓%s %s\n' "$GREEN"  "$(_ts)" "$RESET" "$*" | tee -a "$LOG_FILE"; }
log_warn() { printf '%s[%s] ⚠%s %s\n' "$YELLOW" "$(_ts)" "$RESET" "$*" | tee -a "$LOG_FILE"; }
log_err()  { printf '%s[%s] ✗%s %s\n' "$RED"    "$(_ts)" "$RESET" "$*" | tee -a "$LOG_FILE" >&2; }
log_step() {
    printf '\n%s%s═══════════════════════════════════════════════════════════════%s\n' "$CYAN" "$BOLD" "$RESET" | tee -a "$LOG_FILE"
    printf '%s%s  PASSO %s %s%s\n' "$CYAN" "$BOLD" "$1" "$2" "$RESET" | tee -a "$LOG_FILE"
    printf '%s%s═══════════════════════════════════════════════════════════════%s\n\n' "$CYAN" "$BOLD" "$RESET" | tee -a "$LOG_FILE"
}

die() { log_err "$*"; exit 1; }

usage() {
    sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

confirm() {
    local msg="$1" default="${2:-N}" ans
    if [[ "$AUTO_YES" -eq 1 ]]; then
        log "[auto-yes] $msg → sim"
        return 0
    fi
    local prompt="[s/N]"
    [[ "$default" == "S" ]] && prompt="[S/n]"
    read -r -p "$(printf '%s %s: ' "$msg" "$prompt")" ans || true
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[sSyY]$ ]]
}

prompt_input() {
    local msg="$1" default="${2:-}" ans
    if [[ -n "$default" ]]; then
        read -r -p "$(printf '%s [%s]: ' "$msg" "$default")" ans || true
        echo "${ans:-$default}"
    else
        read -r -p "$(printf '%s: ' "$msg")" ans || true
        echo "$ans"
    fi
}

require_root() {
    [[ $EUID -eq 0 ]] || die "Execute como root (sudo $0)."
}

check_ubuntu() {
    [[ -f /etc/os-release ]] || die "/etc/os-release não encontrado. Este script é para Ubuntu."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || die "Este script é para Ubuntu (detectado: ${ID:-desconhecido})."
    local major="${VERSION_ID%%.*}"
    [[ "$major" -ge 22 ]] || die "Ubuntu 22+ é requerido (detectado: ${VERSION_ID})."
    log_ok "Sistema: Ubuntu ${VERSION_ID} (${VERSION_CODENAME})"
}

detect_arch() {
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
        amd64|arm64) log_ok "Arquitetura: ${ARCH}" ;;
        *) die "Arquitetura não suportada: $ARCH (esperado amd64 ou arm64)" ;;
    esac
}

init_log_file() {
    LOG_FILE="/var/log/config-server-$(date '+%Y%m%d-%H%M%S').log"
    : > "$LOG_FILE"
    chmod 640 "$LOG_FILE"
}

# Insere ou atualiza bloco marcado em um arquivo (idempotente)
upsert_block() {
    local file="$1" content="$2"
    local tmp
    tmp="$(mktemp)"
    if [[ -f "$file" ]] && grep -qF "$MARKER_BEGIN" "$file"; then
        awk -v b="$MARKER_BEGIN" -v e="$MARKER_END" '
            $0==b {skip=1; next}
            $0==e {skip=0; next}
            !skip {print}
        ' "$file" > "$tmp"
    else
        [[ -f "$file" ]] && cat "$file" > "$tmp" || true
    fi
    # Garante que o arquivo termine com newline antes de anexar o bloco
    if [[ -s "$tmp" ]] && [[ "$(tail -c 1 "$tmp" | xxd -p)" != "0a" ]]; then
        echo "" >> "$tmp"
    fi
    {
        cat "$tmp"
        echo "$MARKER_BEGIN"
        printf '%s\n' "$content"
        echo "$MARKER_END"
    } > "${file}.new"
    mv "${file}.new" "$file"
    rm -f "$tmp"
}

# =============================================================================
# Parse de argumentos
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --only)      IFS=',' read -r -a ONLY_STEPS <<< "$2"; shift 2 ;;
            --skip)      IFS=',' read -r -a SKIP_STEPS <<< "$2"; shift 2 ;;
            --kuma-url)      KUMA_URL="$2"; shift 2 ;;
            --monitor-path)  MONITOR_PATH="$2"; shift 2 ;;
            --no-mount)      NO_MOUNT=1; shift ;;
            --yes|-y)    AUTO_YES=1; shift ;;
            -h|--help)   usage 0 ;;
            *) die "Opção desconhecida: $1 (use -h para ajuda)" ;;
        esac
    done

    if [[ ${#ONLY_STEPS[@]} -gt 0 ]]; then
        STEPS_TO_RUN=("${ONLY_STEPS[@]}")
    else
        STEPS_TO_RUN=("${STEPS_AVAILABLE[@]}")
        for s in "${SKIP_STEPS[@]:-}"; do
            [[ -z "$s" ]] && continue
            STEPS_TO_RUN=("${STEPS_TO_RUN[@]/$s}")
        done
    fi
    [[ "$NO_MOUNT" -eq 1 ]] && STEPS_TO_RUN=("${STEPS_TO_RUN[@]/4}")

    # limpa vazios
    local tmp=()
    for s in "${STEPS_TO_RUN[@]}"; do [[ -n "$s" ]] && tmp+=("$s"); done
    STEPS_TO_RUN=("${tmp[@]}")
}

# =============================================================================
# Coleta de inputs (antes de executar)
# =============================================================================
collect_inputs() {
    if _will_run 5 && [[ -z "$KUMA_URL" ]]; then
        echo
        log "O passo 5 precisa da URL de push do Uptime Kuma."
        log "Exemplo: https://meu-kuma.exemplo.com/push/abc123"
        KUMA_URL="$(prompt_input "URL do Uptime Kuma (vazio = pular passo 5)")"
        if [[ -z "$KUMA_URL" ]]; then
            log_warn "URL vazia. Passo 5 será pulado."
            STEPS_TO_RUN=("${STEPS_TO_RUN[@]/5}")
            local tmp=(); for s in "${STEPS_TO_RUN[@]}"; do [[ -n "$s" ]] && tmp+=("$s"); done
            STEPS_TO_RUN=("${tmp[@]}")
        fi
    fi
}

_will_run() {
    local target="$1"
    for s in "${STEPS_TO_RUN[@]}"; do [[ "$s" == "$target" ]] && return 0; done
    return 1
}

# =============================================================================
# PASSO 1 — Fail2Ban
# =============================================================================
step1_fail2ban() {
    log_step 1 "Fail2Ban para SSH"

    if dpkg -s fail2ban >/dev/null 2>&1; then
        log_ok "fail2ban já instalado, pulando instalação"
    else
        log "Instalando fail2ban..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban
    fi

    if [[ ! -f /etc/fail2ban/fail2ban.local ]]; then
        log "Criando /etc/fail2ban/fail2ban.local (cópia do fail2ban.conf)"
        cp /etc/fail2ban/fail2ban.conf /etc/fail2ban/fail2ban.local
    else
        log_ok "/etc/fail2ban/fail2ban.local já existe"
    fi

    log "Gerando /etc/fail2ban/jail.local (overrides mínimos)"
    cat > /etc/fail2ban/jail.local <<EOF
# Gerenciado por config-server.sh
[DEFAULT]
ignoreip = ${FAIL2BAN_IGNOREIP}
bantime  = ${FAIL2BAN_BANTIME}
maxretry = ${FAIL2BAN_MAXRETRY}

[sshd]
enabled = true
EOF

    log "Reiniciando fail2ban..."
    systemctl enable --now fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban

    sleep 1
    if fail2ban-client status sshd >/dev/null 2>&1; then
        log_ok "Fail2Ban ativo e jail sshd habilitada"
        fail2ban-client status sshd | tee -a "$LOG_FILE"
    else
        log_warn "fail2ban-client status sshd falhou — verifique /var/log/fail2ban.log"
    fi
}

# =============================================================================
# PASSO 2 — Swap + earlyoom (inline)
# =============================================================================
step2_swap_earlyoom() {
    log_step 2 "Swap ${SWAP_SIZE} + earlyoom"

    local swapfile="/swapfile"

    if [[ ! -f "$swapfile" ]]; then
        log "Criando swap de ${SWAP_SIZE} em ${swapfile}..."
        fallocate -l "$SWAP_SIZE" "$swapfile"
        chmod 600 "$swapfile"
        mkswap "$swapfile" >/dev/null
        swapon "$swapfile"
        log_ok "Swap criado e ativado"
    else
        log_ok "${swapfile} já existe"
        swapon --show | grep -q "$swapfile" || swapon "$swapfile"
    fi

    if ! grep -qE '^/swapfile\s+none\s+swap' /etc/fstab; then
        log "Adicionando swap ao /etc/fstab"
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    else
        log_ok "Swap já está no /etc/fstab"
    fi

    log "Ajustando vm.swappiness=10"
    sysctl -q vm.swappiness=10
    if ! grep -q '^vm.swappiness=10' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi

    if dpkg -s earlyoom >/dev/null 2>&1; then
        log_ok "earlyoom já instalado"
    else
        log "Instalando earlyoom..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y earlyoom
    fi

    systemctl enable earlyoom >/dev/null 2>&1 || true
    systemctl restart earlyoom

    log_ok "Swap: $(swapon --show | tail -n +2 | awk '{print $1, $3}' | tr '\n' ' ')"
    log_ok "earlyoom: $(systemctl is-active earlyoom)"
    log_ok "vm.swappiness: $(sysctl -n vm.swappiness)"
}

# =============================================================================
# PASSO 3 — Docker + tuning
# =============================================================================
step3_docker() {
    log_step 3 "Docker + tuning de kernel/rede/limites"

    log "[3.1] apt update && upgrade"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

    _step3_base_packages
    _step3_iptables
    _step3_sysctl
    _step3_limits
    _step3_sysctl_extra
    _step3_install_docker
    _step3_loki_plugin
    _step3_daemon_json
    _step3_gwbridge

    log "Reiniciando Docker..."
    systemctl restart docker
    log_ok "Docker: $(systemctl is-active docker)  |  versão: $(docker --version 2>/dev/null || echo '?')"
}

_step3_base_packages() {
    local pkgs=(btop net-tools)
    local to_install=()
    for p in "${pkgs[@]}"; do
        if dpkg -s "$p" >/dev/null 2>&1; then
            log_ok "[3.1b] ${p} já instalado"
        else
            to_install+=("$p")
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        log "[3.1b] Instalando pacotes utilitários: ${to_install[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}"
    fi
}

_step3_iptables() {
    log "[3.2] Liberando iptables e instalando netfilter-persistent"
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        echo 'iptables-persistent iptables-persistent/autosave_v4 boolean true'  | debconf-set-selections
        echo 'iptables-persistent iptables-persistent/autosave_v6 boolean true'  | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent
    fi
    iptables -I INPUT -j ACCEPT || true
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    netfilter-persistent save >/dev/null
    systemctl is-active netfilter-persistent >/dev/null && log_ok "netfilter-persistent ativo" || log_warn "netfilter-persistent inativo"
}

_step3_sysctl() {
    log "[3.3] Aplicando tuning em /etc/sysctl.conf"
    local content
    content="$(cat <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
# Aumentar número máximo de conexões simultâneas
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_max_tw_buckets = 2000000
net.ipv4.tcp_synack_retries = 2
# Manuseio de pacotes
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_window_scaling = 1
# Evitar TIME_WAIT excessivo (tcp_tw_recycle foi removido em kernels >= 4.12,
# mantido por compatibilidade; pode aparecer warning ao aplicar)
net.ipv4.tcp_tw_recycle = 0
EOF
)"
    # módulo br_netfilter pra que bridge-nf-call-* funcione
    modprobe br_netfilter 2>/dev/null || true
    echo "br_netfilter" > /etc/modules-load.d/br_netfilter.conf

    upsert_block /etc/sysctl.conf "$content"
    sysctl -p 2>&1 | grep -v 'tcp_tw_recycle' | tee -a "$LOG_FILE" || true
}

_step3_limits() {
    log "[3.4] Ajustando limites (ulimit) em /etc/security/limits.conf e systemd"
    local limits_content
    limits_content="$(cat <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
)"
    upsert_block /etc/security/limits.conf "$limits_content"

    local systemd_content
    systemd_content="$(cat <<'EOF'
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF
)"
    upsert_block /etc/systemd/system.conf "$systemd_content"
    upsert_block /etc/systemd/user.conf   "$systemd_content"

    systemctl daemon-reexec
    log_ok "Limites aplicados (systemctl daemon-reexec executado)"
}

_step3_sysctl_extra() {
    log "[3.5] Tuning adicional (99-tcp-backlog.conf)"
    sysctl -q -w net.ipv4.tcp_tw_reuse=1
    sysctl -q -w net.ipv4.tcp_fin_timeout=30
    sysctl -q -w net.core.somaxconn=65535
    sysctl -q -w net.ipv4.tcp_max_syn_backlog=16384

    cat > /etc/sysctl.d/99-tcp-backlog.conf <<'EOF'
# Gerenciado por config-server.sh
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 16384
EOF
    sysctl --system >/dev/null 2>&1 || true
    log_ok "Tuning adicional aplicado"
}

_step3_install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_ok "[3.6] Docker já instalado: $(docker --version)"
        return 0
    fi
    log "[3.6] Instalando Docker CE..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        apt-transport-https ca-certificates curl software-properties-common

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    . /etc/os-release
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker >/dev/null 2>&1 || true
    log_ok "Docker instalado"
}

_step3_loki_plugin() {
    local plugin="grafana/loki-docker-driver:${LOKI_DRIVER_VERSION}-${ARCH}"
    log "[3.7] Loki Docker driver: ${plugin}"
    if docker plugin ls --format '{{.Name}}' 2>/dev/null | grep -q '^loki'; then
        log_ok "Plugin loki já instalado"
    else
        docker plugin install "$plugin" --alias loki --grant-all-permissions
        log_ok "Plugin loki instalado"
    fi
}

_step3_daemon_json() {
    log "[3.8] Escrevendo /etc/docker/daemon.json"
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "default-ulimits": {
    "nofile": {
      "Name": "nofile",
      "Hard": 1048576,
      "Soft": 1048576
    }
  },
  "exec-opts": ["native.cgroupdriver=systemd"],
  "max-concurrent-downloads": 10,
  "max-concurrent-uploads": 10,
  "mtu": ${DOCKER_MTU},
  "min-api-version": "1.41"
}
EOF
}

_step3_gwbridge() {
    log "[3.9] Recriando rede docker_gwbridge (subnet=${DOCKER_GWBRIDGE_SUBNET}, mtu=${DOCKER_MTU})"
    # Só recria se não estiver em uso (swarm ativo impede remoção)
    if docker network inspect docker_gwbridge >/dev/null 2>&1; then
        if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -qi active; then
            log_warn "Swarm ativo — não é seguro remover docker_gwbridge. Deixando como está."
            return 0
        fi
        docker network rm docker_gwbridge >/dev/null 2>&1 || log_warn "Falha ao remover docker_gwbridge (pode estar em uso)"
    fi
    docker network create \
        --subnet "${DOCKER_GWBRIDGE_SUBNET}" \
        --opt com.docker.network.bridge.name=docker_gwbridge \
        --opt com.docker.network.driver.mtu="${DOCKER_MTU}" \
        docker_gwbridge >/dev/null 2>&1 || log_warn "Não foi possível criar docker_gwbridge (pode já existir)"
}

# =============================================================================
# PASSO 4 — Auto-montagem de discos
# =============================================================================
step4_mount_disks() {
    log_step 4 "Auto-montagem de Block Storage anexado"

    log "Discos detectados:"
    lsblk -o NAME,FSTYPE,SIZE,MOUNTPOINT,UUID | tee -a "$LOG_FILE"
    echo

    if ! confirm "Deseja configurar montagem automática de algum disco?"; then
        log "Passo 4 pulado pelo usuário"
        return 0
    fi

    while true; do
        echo
        local dev; dev="$(prompt_input "Informe o dispositivo (ex: sda, sdb, sdc1) ou vazio para sair")"
        [[ -z "$dev" ]] && break
        _mount_one_disk "$dev" || log_warn "Falha ao configurar /dev/${dev}"
        echo
        confirm "Configurar outro disco?" "N" || break
    done
}

_mount_one_disk() {
    local dev="$1"
    local path="/dev/${dev}"

    [[ -b "$path" ]] || { log_err "Dispositivo ${path} não existe"; return 1; }

    local fstype uuid
    fstype="$(lsblk -no FSTYPE "$path" 2>/dev/null | head -n1)"
    uuid="$(lsblk -no UUID "$path" 2>/dev/null | head -n1)"

    # Sem filesystem → precisa formatar (e geralmente é disco inteiro, precisa particionar)
    if [[ -z "$fstype" ]]; then
        log_warn "${path} não tem filesystem."
        # Se é disco (não partição), particiona primeiro
        local devtype
        devtype="$(lsblk -no TYPE "$path" 2>/dev/null | head -n1)"
        if [[ "$devtype" == "disk" ]]; then
            log "É um disco sem partição. Vou criar uma partição primária (/dev/${dev}1)."
            echo "  ${RED}${BOLD}ATENÇÃO:${RESET} isso destruirá qualquer dado existente em ${path}"
            local confirm_dev
            confirm_dev="$(prompt_input "Digite '${dev}' para confirmar formatação")"
            [[ "$confirm_dev" == "$dev" ]] || { log_err "Confirmação inválida, abortando este disco"; return 1; }

            log "Criando partição em ${path}..."
            printf 'n\np\n1\n\n\nw\n' | fdisk "$path" >/dev/null
            partprobe "$path"
            sleep 1

            local part="/dev/${dev}1"
            [[ -b "$part" ]] || { log_err "Partição ${part} não apareceu após fdisk/partprobe"; return 1; }

            log "Criando filesystem ext4 em ${part}..."
            mkfs.ext4 -F "$part" >/dev/null
            dev="${dev}1"; path="$part"
            uuid="$(blkid -s UUID -o value "$path")"
            fstype="ext4"
        else
            # Partição sem FS: só formatar
            local confirm_dev
            confirm_dev="$(prompt_input "Digite '${dev}' para formatar em ext4 (destruirá dados)")"
            [[ "$confirm_dev" == "$dev" ]] || { log_err "Confirmação inválida, abortando"; return 1; }
            mkfs.ext4 -F "$path" >/dev/null
            uuid="$(blkid -s UUID -o value "$path")"
            fstype="ext4"
        fi
    fi

    [[ -z "$uuid" ]] && uuid="$(blkid -s UUID -o value "$path" || true)"
    [[ -n "$uuid" ]] || { log_err "Não consegui obter UUID de ${path}"; return 1; }

    local mountname mountpoint
    mountname="$(prompt_input "Nome do volume (será montado em /mnt/<nome>)" "volume1")"
    mountpoint="/mnt/${mountname}"

    mkdir -p "$mountpoint"

    if grep -qE "^UUID=${uuid}\s" /etc/fstab; then
        log_ok "Entrada já existe em /etc/fstab, pulando"
    else
        log "Adicionando ao /etc/fstab: UUID=${uuid} ${mountpoint} ${fstype} defaults,nofail 0 2"
        echo "UUID=${uuid}   ${mountpoint}   ${fstype}   defaults,nofail   0   2" >> /etc/fstab
    fi

    log "Testando montagem (mount -a)..."
    if mount -a; then
        systemctl daemon-reload
        log_ok "Montado: $(df -h "$mountpoint" | tail -n1)"
    else
        log_err "mount -a falhou — revise /etc/fstab"
        return 1
    fi
}

# =============================================================================
# PASSO 5 — disk-check.sh + cron
# =============================================================================
_detect_mount_candidates() {
    # Lista "/" + qualquer /mnt/* que seja ponto de montagem real
    local -a candidates=("/")
    local mp
    while IFS= read -r mp; do
        [[ -n "$mp" ]] && candidates+=("$mp")
    done < <(findmnt -rno TARGET 2>/dev/null | awk '/^\/mnt\//')
    printf '%s\n' "${candidates[@]}"
}

_choose_monitor_path() {
    if [[ -n "$MONITOR_PATH" ]]; then
        log_ok "Usando path informado via flag: ${MONITOR_PATH}"
        mountpoint -q "$MONITOR_PATH" 2>/dev/null || \
            log_warn "${MONITOR_PATH} não parece ser um ponto de montagem — seguindo mesmo assim"
        return 0
    fi

    local -a candidates=()
    local line
    while IFS= read -r line; do candidates+=("$line"); done < <(_detect_mount_candidates)

    if [[ ${#candidates[@]} -eq 1 ]]; then
        MONITOR_PATH="${candidates[0]}"
        log_ok "Único ponto de montagem detectado: ${MONITOR_PATH}"
        return 0
    fi

    echo
    log "Pontos de montagem candidatos:"
    local i=1
    for c in "${candidates[@]}"; do
        local info
        info="$(df -hP "$c" 2>/dev/null | awk 'NR==2 {printf "%s usado de %s (%s)", $3, $2, $5}')"
        printf '  [%d] %-25s  %s\n' "$i" "$c" "$info" | tee -a "$LOG_FILE"
        i=$((i+1))
    done

    local choice
    while true; do
        choice="$(prompt_input "Qual ponto de montagem monitorar? (número)" "1")"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
            MONITOR_PATH="${candidates[$((choice-1))]}"
            log_ok "Selecionado: ${MONITOR_PATH}"
            return 0
        fi
        log_warn "Escolha inválida. Tente novamente."
    done
}

step5_disk_check() {
    log_step 5 "Monitoramento de disco + Uptime Kuma"

    [[ -n "$KUMA_URL" ]] || die "KUMA_URL vazia — passo 5 não pode rodar"

    _choose_monitor_path

    local script_path="/usr/local/bin/disk-check.sh"
    log "Criando ${script_path} (monitorando ${MONITOR_PATH})"

    cat > "$script_path" <<EOF
#!/usr/bin/env bash
# Gerenciado por config-server.sh
KUMA_PUSH_URL="${KUMA_URL}"
MONITOR_PATH="${MONITOR_PATH}"
THRESHOLD=85
LOG_FILE="/var/log/disk_monitor.log"

USAGE=\$(df -P "\$MONITOR_PATH" | awk 'NR==2 { gsub(/%/,""); print \$5 }')

if [ "\$USAGE" -ge "\$THRESHOLD" ]; then
  curl -L --fail --silent --show-error --max-time 10 "\$KUMA_PUSH_URL" \\
    && echo "\$(date '+%F %T') → Uso: \${USAGE}% (>=\${THRESHOLD}%), alerta enviado." \\
    || echo "\$(date '+%F %T') → Falha ao notificar Uptime Kuma."
else
  echo "\$(date '+%F %T') → Uso: \${USAGE}% (<\${THRESHOLD}%), tudo OK."
fi >> "\$LOG_FILE" 2>&1
EOF
    chmod +x "$script_path"

    log "Testando execução do disk-check..."
    "$script_path" || log_warn "Execução teste retornou erro"
    tail -n 3 /var/log/disk_monitor.log 2>/dev/null | tee -a "$LOG_FILE" || true

    log "Criando cron job em /etc/cron.d/disk-check (a cada 10 min)"
    cat > /etc/cron.d/disk-check <<EOF
# Gerenciado por config-server.sh
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/10 * * * * root ${script_path}
EOF
    chmod 644 /etc/cron.d/disk-check
    log_ok "Cron instalado"
}

# =============================================================================
# Main
# =============================================================================
banner() {
    printf '%s%s' "$BOLD" "$CYAN"
    cat <<'EOF'
╔═══════════════════════════════════════════════════════════════╗
║           config-server.sh — provisionamento de servidor      ║
║           Oracle Cloud / Ubuntu 22+                           ║
╚═══════════════════════════════════════════════════════════════╝
EOF
    printf '%s' "$RESET"
}

summary() {
    echo
    printf '%s%s═══════════════════════════════════════════════════════════════%s\n' "$GREEN" "$BOLD" "$RESET"
    log_ok "Configuração concluída"
    log_ok "Log salvo em: ${LOG_FILE}"
    printf '%s%s═══════════════════════════════════════════════════════════════%s\n' "$GREEN" "$BOLD" "$RESET"
}

prompt_reboot() {
    echo
    log_warn "Recomenda-se reiniciar o servidor para que todos os ajustes"
    log_warn "(ulimits, sysctl, systemd) sejam aplicados em processos novos."
    echo
    if [[ "$AUTO_YES" -eq 1 ]]; then
        log "[auto-yes] Reiniciando em 10 segundos... (Ctrl+C para abortar)"
        sleep 10
        systemctl reboot
        return
    fi
    if confirm "Reiniciar o servidor agora?" "N"; then
        log "Reiniciando o servidor em 5 segundos..."
        sleep 5
        systemctl reboot
    else
        log "Reboot adiado. Lembre-se de reiniciar manualmente com: sudo systemctl reboot"
    fi
}

main() {
    require_root
    init_log_file
    banner
    log "Log: ${LOG_FILE}"
    parse_args "$@"
    check_ubuntu
    detect_arch
    collect_inputs

    log "Passos a executar: ${STEPS_TO_RUN[*]:-nenhum}"
    [[ ${#STEPS_TO_RUN[@]} -eq 0 ]] && { log_warn "Nenhum passo selecionado"; exit 0; }

    for step in "${STEPS_TO_RUN[@]}"; do
        case "$step" in
            1) step1_fail2ban ;;
            2) step2_swap_earlyoom ;;
            3) step3_docker ;;
            4) step4_mount_disks ;;
            5) step5_disk_check ;;
            *) log_warn "Passo desconhecido: $step" ;;
        esac
    done

    summary
    prompt_reboot
}

main "$@"
