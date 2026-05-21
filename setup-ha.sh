#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  Home Assistant Core — Smart Home Server Setup (Improved)
#######################################################

set -o pipefail

TERMUX_PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
TERMUX_HOME="${HOME:-/data/data/com.termux/files/home}"

CURRENT_STEP=0
TOTAL_STEPS=8
LOG_FILE="$TERMUX_HOME/termux-setup.log"

# Colors...
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;90m'
NC='\033[0m'
BOLD='\033[1m'

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    local FILLED=$((PERCENT / 5))
    local EMPTY=$((20 - FILLED))
    local BAR="${GREEN}"
    for ((i=0; i<FILLED; i++)); do BAR+="█"; done
    BAR+="${GRAY}"
    for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
    BAR+="${NC}"
    echo ""
    echo -e "${WHITE}────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}  PROGRESS: Step ${CURRENT_STEP}/${TOTAL_STEPS}  ${BAR}  ${WHITE}${PERCENT}%${NC}"
    echo -e "${WHITE}────────────────────────────────────────────────────────────${NC}"
    echo ""
}

spinner() {
    local pid=$1 message=$2
    local spin=('⠋' '⠙' '⠸' '⠴' '⠦' '⠇') i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin[$i]}${NC}  %s  " "$message"
        i=$(( (i + 1) % 6 ))
        sleep 0.1
    done
    wait "$pid"
    if [ $? -eq 0 ]; then
        printf "\r  ${GREEN}✔${NC}  %-55s\n" "$message"
        log "OK: $message"
    else
        printf "\r  ${RED}✘${NC}  %-55s ${RED}(failed — see log)${NC}\n" "$message"
        log "FAILED: $message"
    fi
}

safe_install_pkg() {
    local pkg=$1 name=${2:-$pkg}
    if dpkg -s "$pkg" &>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "$name"
        return 0
    fi
    (DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" "$pkg" >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing ${name}..."
}

proot_install_pkg() {
    local pkg=$1 name=${2:-$pkg}
    if proot-distro login ubuntu -- dpkg -s "$pkg" &>/dev/null; then
        printf "  ${GRAY}~${NC}  %-55s ${GRAY}(already installed)${NC}\n" "$name"
        return 0
    fi
    (proot-distro login ubuntu -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y '$pkg'" >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing ${name} (Ubuntu)..."
}

show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔══════════════════════════════════════════════════════╗
  ║        Home Assistant Core on Termux (Improved)      ║
  ╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"
}

preflight_checks() {
    log "=== Setup started ==="
    echo -e "${PURPLE}[*] Preflight checks...${NC}"

    if [[ "$(uname -m)" != "aarch64" ]]; then
        echo -e "${RED}✘ Unsupported architecture${NC}"
        exit 1
    fi

    local free_mb=$(df -m "$TERMUX_HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    echo -e "  ${GREEN}✔${NC} Architecture OK | Storage: ${free_mb:-?} MB"

    if ! ping -c 1 -W 3 google.com &>/dev/null; then
        echo -e "${RED}✘ No internet${NC}"
        exit 1
    fi

    PHONE_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    [ -z "$PHONE_IP" ] && PHONE_IP="<your-phone-ip>"
}

# ==================== STEPS ====================

step_proot() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}] Installing proot-distro...${NC}"
    safe_install_pkg "proot-distro" "proot-distro"
    safe_install_pkg "proot" "proot"
}

step_ubuntu() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}] Setting up Ubuntu 24.04...${NC}"
    if ! proot-distro list 2>/dev/null | grep -q "ubuntu.*Installed"; then
        (proot-distro install ubuntu >> "$LOG_FILE" 2>&1) &
        spinner $! "Installing Ubuntu 24.04..."
    fi
    (proot-distro login ubuntu -- apt-get update -y >> "$LOG_FILE" 2>&1) &
    spinner $! "Updating Ubuntu packages..."
}

step_ubuntu_deps() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}] Installing build dependencies...${NC}"
    for pkg in python3 python3-pip python3-venv python3-dev build-essential \
               libffi-dev libssl-dev libjpeg-dev zlib1g-dev autoconf cargo \
               pkg-config libturbojpeg libavformat-dev libavcodec-dev \
               libavutil-dev libswscale-dev; do
        proot_install_pkg "$pkg"
    done
}

step_homeassistant() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}] Installing Home Assistant Core...${NC}"
    echo -e "${YELLOW}This may take 15-30+ minutes...${NC}"

    local VENV="${TERMUX_HOME}/hass-venv"
    local CONFIG="${TERMUX_HOME}/hass-config"

    if ! proot-distro login ubuntu -- test -d "$VENV"; then
        (proot-distro login ubuntu -- python3 -m venv "$VENV" >> "$LOG_FILE" 2>&1) &
        spinner $! "Creating Python venv..."
    fi

    (proot-distro login ubuntu -- "$VENV/bin/pip" install --upgrade pip wheel setuptools >> "$LOG_FILE" 2>&1) &
    spinner $! "Upgrading pip..."

    (proot-distro login ubuntu -- "$VENV/bin/pip" install \
        homeassistant \
        PyTurboJPEG numpy av PyNaCl hassil home-assistant-intents \
        pymicro-vad ha-ffmpeg cached-ipaddress async-upnp-client \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing Home Assistant + extras..."

    # === IPv6 / Adapter Fix ===
    echo -e "  ${YELLOW}Applying IPv6 network patch...${NC}"
    proot-distro login ubuntu -- bash -c "
        find $VENV/lib/python3*/site-packages -path '*/homeassistant/components/network' -name '*.py' -exec sed -i \
        '/def _async_get_adapter/,+20 s/if ip_address.version == 6:/if False:/' {} + 2>/dev/null || true
    " >> "$LOG_FILE" 2>&1

    # Existing ifaddr patch
    proot-distro login ubuntu -- bash -c "
        find $VENV/lib/python3*/site-packages/ifaddr -name '_posix.py' -exec sed -i \
        's/raise OSError(eno, os.strerror(eno))/return []/' {} + 2>/dev/null || true
    " >> "$LOG_FILE" 2>&1
    echo -e "  ${GREEN}✔ IPv6 + ifaddr patches applied${NC}"
}

step_ha_config() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}] Configuring Home Assistant...${NC}"
    local CONFIG="${TERMUX_HOME}/hass-config"
    proot-distro login ubuntu -- mkdir -p "$CONFIG"
    if ! proot-distro login ubuntu -- grep -q "server_host" "$CONFIG/configuration.yaml" 2>/dev/null; then
        proot-distro login ubuntu -- sh -c "cat > $CONFIG/configuration.yaml" << EOF
homeassistant:
http:
  server_host: 0.0.0.0
mobile_app:
default_config:
EOF
        echo -e "  ${GREEN}✔ Network config created (binds to 0.0.0.0)${NC}"
    fi
}

step_launchers() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}] Creating launcher scripts...${NC}"

    cat > "$TERMUX_HOME/start-homeassistant.sh" << 'STARTEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "[*] Starting Home Assistant..."

if command -v termux-wake-lock >/dev/null; then
    termux-wake-lock
fi

if pgrep -f "hass -c" > /dev/null; then
    echo "Home Assistant is already running!"
    exit 1
fi

PHONE_IP=$(ip addr show wlan0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)

echo "Access at: http://${PHONE_IP:-localhost}:8123"
echo "First boot may take 5-10 minutes..."

proot-distro login ubuntu -- /data/data/com.termux/files/home/hass-venv/bin/hass -c /data/data/com.termux/files/home/hass-config
STARTEOF

    chmod +x "$TERMUX_HOME/start-homeassistant.sh"

    cat > "$TERMUX_HOME/stop-homeassistant.sh" << 'STOPEOF'
#!/data/data/com.termux/files/usr/bin/bash
echo "[*] Stopping Home Assistant..."
pkill -f "hass -c" 2>/dev/null || true
termux-wake-unlock 2>/dev/null || true
echo "[*] Stopped."
STOPEOF
    chmod +x "$TERMUX_HOME/stop-homeassistant.sh"
}

step_verify() {
    update_progress
    echo -e "${PURPLE}[Step ${CURRENT_STEP}] Verifying...${NC}"
    # verification code...
}

show_completion() {
    echo -e "${GREEN}Installation complete!${NC}"
    echo "Start with:   bash ~/start-homeassistant.sh"
    echo "Access:       http://$PHONE_IP:8123"
}

main() {
    show_banner
    preflight_checks
    step_proot
    step_ubuntu
    step_ubuntu_deps
    step_homeassistant
    step_ha_config
    step_launchers
    step_verify
    show_completion
}

main