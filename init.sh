#!/usr/bin/env bash
#
# init.sh — CachyOS live-environment bootstrap
# --------------------------------------------
# Curl this down on first boot:
#   curl -fsSL https://raw.githubusercontent.com/nulmind/dotfiles/main/init.sh | bash
#
# Order is deliberate so you can hand off to remote/agent config early:
#   network → packages → AWUS036ACH driver → SSH → Tailscale → Claude Code → dotfiles
#
# Idempotent: safe to re-run. Fail-fast: a failed step stops the script.

set -euo pipefail
trap 'echo "❌  init.sh failed at line ${LINENO} — command: ${BASH_COMMAND}" >&2' ERR

DOTFILES="${DOTFILES:-https://raw.githubusercontent.com/nulmind/dotfiles/main}"

# Load local overrides / secrets if present (kept out of git via .gitignore).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo .)"
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"

# ── Network constants (edit these if your setup changes) ───────
STATIC_IP="${STATIC_IP:-172.16.1.14/16}"
STATIC_GW="${STATIC_GW:-172.16.0.254}"
STATIC_DNS="${STATIC_DNS:-168.95.1.1,168.95.192.1}"
HOTSPOT_SSID="${HOTSPOT_SSID:-michaels iphone}"
HOTSPOT_PASS="${HOTSPOT_PASS:-}"   # set in .env — never commit the password

# ── 0. Persistence check ───────────────────────────────────────
if ! findmnt -n -o FSTYPE / 2>/dev/null | grep -q overlay; then
  echo "⚠️   WARNING: root is not an overlayfs — changes will be lost on reboot."
  read -rp "Continue anyway? [y/N] " _ok
  [[ "${_ok,,}" == "y" ]] || { echo "Aborted."; exit 1; }
fi

# ── 1. Network connectivity ────────────────────────────────────
online() { ping -c1 -W3 1.1.1.1 &>/dev/null; }

setup_network() {
  echo "── Checking network ──"

  # Path 1: already online
  if online; then
    echo "✅  Already connected — skipping network setup."; return 0
  fi

  # Path 2: static Ethernet
  local ETH
  ETH=$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null \
        | awk -F: '$2=="ethernet"{print $1}' | head -1)
  if [[ -n "${ETH}" ]]; then
    echo "Trying static Ethernet on ${ETH} (${STATIC_IP})..."
    nmcli connection delete "cachyos-static-eth" &>/dev/null || true
    nmcli connection add type ethernet \
      con-name    "cachyos-static-eth" \
      ifname      "${ETH}" \
      ipv4.method manual \
      ipv4.addresses "${STATIC_IP}" \
      ipv4.gateway   "${STATIC_GW}" \
      ipv4.dns       "${STATIC_DNS}" \
      ipv6.method    auto \
      connection.autoconnect yes &>/dev/null || true
    nmcli connection up "cachyos-static-eth" &>/dev/null || true
    sleep 4
    if online; then echo "✅  Static Ethernet connected."; return 0; fi
    echo "⚠️   Static Ethernet did not reach the internet — trying hotspot..."
  fi

  # Path 3: iPhone hotspot (credentials from .env)
  if [[ -n "${HOTSPOT_PASS}" ]]; then
    echo "Connecting to hotspot: \"${HOTSPOT_SSID}\" ..."
    nmcli radio wifi on 2>/dev/null || true
    sleep 2
    nmcli device wifi connect "${HOTSPOT_SSID}" password "${HOTSPOT_PASS}" &>/dev/null || true
    sleep 5
    if online; then echo "✅  Connected via iPhone hotspot."; return 0; fi
    echo "⚠️   Hotspot not reachable — falling back to manual WiFi..."
  else
    echo "(No HOTSPOT_PASS in .env — skipping hotspot path.)"
  fi

  # Path 4: manual WiFi
  echo "── Available WiFi networks ──"
  nmcli device wifi list || true
  local SSID PASS
  read -rp  "WiFi SSID     : " SSID
  read -rsp "WiFi password : " PASS; echo
  nmcli device wifi connect "${SSID}" password "${PASS}"
  sleep 4
  if online; then
    echo "✅  Connected via WiFi (${SSID})."
  else
    echo "❌  All network paths failed. Fix connectivity and re-run."; exit 1
  fi
}
setup_network

# ── 2. Package database update ─────────────────────────────────
echo "── Updating pacman database ──"
sudo pacman -Sy --noconfirm

# helper: install only if missing (keeps the run idempotent)
pac() {
  local missing=()
  for p in "$@"; do
    pacman -Qq "$p" &>/dev/null || missing+=("$p")
  done
  (( ${#missing[@]} )) && sudo pacman -S --noconfirm --needed "${missing[@]}" || true
}

# ── 3. Core packages ───────────────────────────────────────────
echo "── Installing packages ──"
if curl -fsSL "${DOTFILES}/packages.txt" -o /tmp/packages.txt 2>/dev/null; then
  mapfile -t PKGS < <(sed 's/#.*//' /tmp/packages.txt | grep -vE '^\s*$')
  (( ${#PKGS[@]} )) && pac "${PKGS[@]}"
else
  echo "(Could not fetch packages.txt — skipping bulk package install.)"
fi

# ── 3b. AWUS036ACH WiFi adapter driver (Realtek RTL8812AU) ─────
# The Alfa AWUS036ACH uses the RTL8812AU chipset, which is NOT in the
# mainline kernel. It needs the out-of-tree rtl8812au DKMS module.
setup_awus036ach() {
  echo "── Setting up AWUS036ACH (RTL8812AU) driver ──"

  # If the device is present, log what the kernel sees.
  if command -v lsusb &>/dev/null; then
    lsusb | grep -iE '0bda:(8812|881a|8813)|Realtek.*8812' \
      && echo "   AWUS036ACH detected on USB." \
      || echo "   (Adapter not currently plugged in — installing driver anyway.)"
  fi

  # DKMS needs the headers for every installed kernel.
  echo "   Installing DKMS + kernel headers..."
  pac dkms
  # CachyOS default kernel headers, with a stock-Arch fallback.
  sudo pacman -S --noconfirm --needed linux-cachyos-headers 2>/dev/null \
    || sudo pacman -S --noconfirm --needed linux-headers 2>/dev/null || true

  # Already loaded? Then we're done.
  if lsmod 2>/dev/null | grep -q '^8812au'; then
    echo "✅  8812au module already loaded."
    return 0
  fi

  # Try the official repo package first, then AUR via paru.
  if pacman -Si rtl8812au-dkms-git &>/dev/null; then
    pac rtl8812au-dkms-git
  elif command -v paru &>/dev/null; then
    paru -S --noconfirm --needed rtl8812au-dkms-git || true
  elif command -v yay &>/dev/null; then
    yay -S --noconfirm --needed rtl8812au-dkms-git || true
  else
    # Last resort: build straight from the maintained source tree.
    echo "   No AUR helper found — building from source (aircrack-ng/rtl8812au)..."
    pac git base-devel
    tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/aircrack-ng/rtl8812au.git "${tmp}/rtl8812au" \
      && ( cd "${tmp}/rtl8812au" && sudo make dkms_install ) || \
      echo "⚠️   rtl8812au build failed — configure manually after boot."
  fi

  sudo modprobe 8812au 2>/dev/null || true
  if lsmod 2>/dev/null | grep -q '^8812au'; then
    echo "✅  AWUS036ACH driver loaded (8812au)."
  else
    echo "⚠️   8812au not loaded yet — a reboot may be required for DKMS to finish."
  fi
}
setup_awus036ach

# ── 3c. GPU driver ─────────────────────────────────────────────
setup_gpu() {
  echo "── Setting up GPU driver ──"

  # Detect vendor from lspci PCI class 0300/0302 (VGA / 3D controller)
  local GPU_LINE VENDOR_ID
  GPU_LINE=$(lspci -nn 2>/dev/null \
    | grep -iE '\[03(00|01|02)\]' | head -1)
  if [[ -z "${GPU_LINE}" ]]; then
    echo "   (No discrete GPU detected — skipping.)"
    return 0
  fi
  echo "   Detected: ${GPU_LINE}"

  # Extract 4-digit vendor ID from the [vvvv:dddd] suffix
  VENDOR_ID=$(echo "${GPU_LINE}" | grep -oP '\[\K[0-9a-fA-F]{4}(?=:[0-9a-fA-F]{4}\])' | head -1)

  case "${VENDOR_ID,,}" in
    10de)  _setup_nvidia ;;
    1002)  _setup_amd    ;;
    8086)  _setup_intel  ;;
    *)     echo "   ⚠️   Unknown GPU vendor ${VENDOR_ID} — skipping auto-setup." ;;
  esac
}

_setup_nvidia() {
  echo "   Vendor: NVIDIA — installing proprietary driver stack"

  # CachyOS ships nvidia-dkms in its repos; prefer it over the AUR.
  pac dkms
  sudo pacman -S --noconfirm --needed linux-cachyos-headers 2>/dev/null \
    || sudo pacman -S --noconfirm --needed linux-headers 2>/dev/null || true

  # Core driver + userspace
  pac nvidia-dkms nvidia-utils nvidia-settings lib32-nvidia-utils

  # Vulkan + VA-API via NVDEC (optional but useful for Blender/ML workloads)
  pac vulkan-icd-loader lib32-vulkan-icd-loader

  # Blacklist nouveau so it doesn't race the proprietary driver at boot
  if [[ ! -f /etc/modprobe.d/blacklist-nouveau.conf ]]; then
    echo -e "blacklist nouveau\noptions nouveau modeset=0" \
      | sudo tee /etc/modprobe.d/blacklist-nouveau.conf > /dev/null
    echo "   Blacklisted nouveau."
  fi

  # Add nvidia to the mkinitcpio MODULES array so the driver loads in initramfs
  # (needed for early KMS / framebuffer on Wayland)
  if ! grep -q 'nvidia' /etc/mkinitcpio.conf 2>/dev/null; then
    sudo sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
      /etc/mkinitcpio.conf
    sudo mkinitcpio -P 2>/dev/null || true
    echo "   Updated mkinitcpio MODULES."
  fi

  # Enable DRM kernel mode-setting (required for Wayland + suspend/resume)
  local CMDLINE=/etc/kernel/cmdline
  if [[ -f "${CMDLINE}" ]] && ! grep -q 'nvidia-drm.modeset' "${CMDLINE}"; then
    sudo sed -i 's/$/ nvidia-drm.modeset=1/' "${CMDLINE}"
    echo "   Added nvidia-drm.modeset=1 to kernel cmdline."
  fi

  # Persist nvidia power management
  pac nvidia-prime 2>/dev/null || true
  sudo systemctl enable nvidia-persistenced 2>/dev/null || true

  # Check driver loaded (won't be until reboot when running from live ISO)
  if lsmod 2>/dev/null | grep -q '^nvidia '; then
    echo "✅  NVIDIA driver loaded."
  else
    echo "⚠️   NVIDIA driver installed — will activate on next boot (expected on live ISO)."
  fi

  # CUDA toolkit (large — skip unless CUDA env var is set)
  if [[ -n "${INSTALL_CUDA:-}" ]]; then
    echo "   Installing CUDA toolkit (this is large)..."
    pac cuda cudnn
  else
    echo "   Tip: re-run with INSTALL_CUDA=1 to also install the CUDA toolkit."
  fi
}

_setup_amd() {
  echo "   Vendor: AMD — installing open-source Mesa stack"
  pac mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver
  echo "✅  AMD Mesa driver installed."
}

_setup_intel() {
  echo "   Vendor: Intel — installing Mesa + intel-media-driver"
  pac mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver
  echo "✅  Intel GPU driver installed."
}

setup_gpu

# Free pacman cache after heavy DKMS + GPU installs to avoid tmpfs pressure
sudo pacman -Scc --noconfirm 2>/dev/null || true

# ── 4. SSH server (enables remote shell access) ────────────────
echo "── Enabling SSH ──"
pac openssh
sudo systemctl enable --now sshd
echo "✅  SSH running. Connect with: ssh $(whoami)@$(hostname -I 2>/dev/null | awk '{print $1}')"

# ── 5. Tailscale (secure remote access + stable IP) ───────────
echo "── Installing Tailscale ──"
pac tailscale
sudo systemctl enable --now tailscaled
echo
echo "Authenticate Tailscale now (a URL will appear — open it on any device):"
sudo tailscale up
TS_IP=$(tailscale ip -4 2>/dev/null || echo "pending")
echo "✅  Tailscale IP: ${TS_IP}"

# ── 6. Claude Code (agent-assisted remote config) ─────────────
echo "── Installing Claude Code ──"
pac nodejs npm
sudo npm install -g @anthropic-ai/claude-code

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo
  echo "Enter your Anthropic API key (from console.anthropic.com/keys)."
  echo "Saved to your shell config so 'claude' works on every boot."
  read -rsp "API key: " _apikey; echo
  if [[ -n "${_apikey}" ]]; then
    echo "export ANTHROPIC_API_KEY='${_apikey}'" >> ~/.bashrc
    mkdir -p ~/.config/fish/conf.d
    printf 'set -gx ANTHROPIC_API_KEY "%s"\n' "${_apikey}" \
      > ~/.config/fish/conf.d/claude_code.fish
    export ANTHROPIC_API_KEY="${_apikey}"
  fi
fi
echo "✅  Claude Code installed. Test with: claude --version"

# ── 6b. Local LLM (offline sysadmin assistant via Ollama) ─────
# Decision tree: GPU VRAM → RAM → tiny fallback.
# Router model (qwen2.5:7b) stays hot on GPU; specialist dispatched per query type.
# Set LOCAL_LLM_MODEL in .env to override auto-detection.
# Set SKIP_LLM=1 to skip entirely (e.g. first boot on a small disk).

# Model sizes in GiB for disk/RAM checks (Q4_K_M quant)
declare -A LLM_SIZES=(
  [qwen2.5-coder:32b]=20 [qwen3:32b]=20 [qwen3:14b]=9
  [deepseek-r1:14b]=9    [phi4:14b]=9   [qwen2.5-coder:7b]=5
  [qwen2.5:7b]=5         [phi4-mini]=3  [qwen3:8b]=5
)

_llm_pick_model() {
  # Returns: PRIMARY_MODEL  ROUTER_MODEL  REASON
  local vram_mb=0 ram_gb=0 nvidia_vram=0

  # — NVIDIA VRAM (MiB) —
  if command -v nvidia-smi &>/dev/null; then
    nvidia_vram=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
                  2>/dev/null | head -1 | tr -d ' ')
    vram_mb="${nvidia_vram:-0}"
  fi

  # — System RAM (GiB) —
  ram_gb=$(awk '/^MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)

  if (( vram_mb >= 30000 )); then
    echo "qwen3:32b qwen2.5:7b GPU≥30GB→qwen3:32b+router"
  elif (( vram_mb >= 22000 )); then
    echo "qwen2.5-coder:32b qwen2.5:7b GPU≥22GB→qwen2.5-coder:32b+router"
  elif (( vram_mb >= 10000 )); then
    echo "qwen3:14b qwen2.5:7b GPU≥10GB→qwen3:14b+router"
  elif (( ram_gb >= 80 )); then
    echo "deepseek-r1:14b none RAM≥80GB→deepseek-r1:14b"
  elif (( ram_gb >= 48 )); then
    echo "phi4:14b none RAM≥48GB→phi4:14b"
  elif (( ram_gb >= 14 )); then
    echo "qwen2.5-coder:7b none RAM≥14GB→qwen2.5-coder:7b"
  else
    echo "phi4-mini none RAM<14GB→phi4-mini(tiny)"
  fi
}

_llm_check_disk() {
  local model="$1" router="$2"
  local needed=0 free_gb
  needed=$(( ${LLM_SIZES[$model]:-10} + ${LLM_SIZES[$router]:-0} + 10 ))
  free_gb=$(df -BG "${OLLAMA_MODELS:-/usr/share/ollama/.ollama/models}" 2>/dev/null \
            | awk 'NR==2{gsub(/G/,"",$4); print $4}' || \
            df -BG /var 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}' || echo 0)
  if (( free_gb < needed )); then
    echo "⚠️   Disk space: need ~${needed}GB free for models, have ${free_gb}GB."
    echo "   Options:"
    echo "     1. Plug in a larger drive and set OLLAMA_MODELS=/mnt/yourdrive/.ollama/models"
    echo "     2. Use a smaller model: SKIP_LLM=1 to skip, or LOCAL_LLM_MODEL=phi4-mini"
    echo "     3. export OLLAMA_MODELS=/path/to/big/drive && re-run init.sh"
    return 1
  fi
  return 0
}

setup_local_llm() {
  if [[ -n "${SKIP_LLM:-}" ]]; then
    echo "── Local LLM skipped (SKIP_LLM set) ──"
    return 0
  fi
  echo "── Setting up local LLM (Ollama) ──"

  # Auto-select model unless overridden
  local selection PRIMARY_MODEL ROUTER_MODEL REASON
  if [[ -n "${LOCAL_LLM_MODEL:-}" ]]; then
    PRIMARY_MODEL="${LOCAL_LLM_MODEL}"
    ROUTER_MODEL="${LOCAL_LLM_ROUTER:-none}"
    REASON="override from .env"
  else
    read -r PRIMARY_MODEL ROUTER_MODEL REASON <<< "$(_llm_pick_model)"
  fi
  echo "   Selected: ${PRIMARY_MODEL} (${REASON})"
  [[ "${ROUTER_MODEL}" != "none" ]] && echo "   Router:   ${ROUTER_MODEL} (always-hot classifier)"

  # Disk space check — bail out gracefully rather than fail mid-pull
  local router_for_check="${ROUTER_MODEL}"
  [[ "${router_for_check}" == "none" ]] && router_for_check=""
  if ! _llm_check_disk "${PRIMARY_MODEL}" "${router_for_check:-}"; then
    echo "   Skipping model pull — fix disk space and re-run, or set SKIP_LLM=1."
    return 0
  fi

  # Install Ollama
  if ! command -v ollama &>/dev/null; then
    echo "   Installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh
  else
    echo "   Ollama $(ollama --version 2>/dev/null) already installed."
  fi

  # Configure Ollama: keep up to 3 models loaded, extend keep-alive for offline use
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_MAX_LOADED_MODELS=3"
Environment="OLLAMA_KEEP_ALIVE=60m"
Environment="OLLAMA_NUM_PARALLEL=2"
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now ollama 2>/dev/null || true

  # Wait for API (up to 30s)
  local tries=0
  until curl -sf http://localhost:11434/api/tags &>/dev/null || (( ++tries >= 30 )); do
    sleep 1
  done
  if (( tries >= 30 )); then
    echo "⚠️   Ollama API not responding — run: ollama pull ${PRIMARY_MODEL}"
    return 0
  fi

  # Pull models
  _llm_pull() {
    local m="$1"
    if ollama list 2>/dev/null | grep -q "^${m}"; then
      echo "   ${m}: already present."
    else
      local sz="${LLM_SIZES[$m]:-?}"
      echo "   Pulling ${m} (~${sz}GB — cached forever after this)..."
      ollama pull "${m}"
    fi
  }
  _llm_pull "${PRIMARY_MODEL}"
  [[ "${ROUTER_MODEL}" != "none" ]] && _llm_pull "${ROUTER_MODEL}"

  # Write /usr/local/bin/ask with smart dispatch
  sudo mkdir -p /usr/local/bin
  # Export vars so the heredoc can see them
  local _primary="${PRIMARY_MODEL}" _router="${ROUTER_MODEL}"
  sudo tee /usr/local/bin/ask > /dev/null << ASKEOF
#!/usr/bin/env bash
# ask — offline sysadmin LLM assistant
# Usage:  ask "how do I configure X"
#         journalctl -xe | ask
#         ask --model qwen3:14b "question"   # force a specific model

PRIMARY="${_primary}"
ROUTER="${_router}"
SYSTEM="You are a concise Linux/Arch/CachyOS sysadmin assistant. \
Give direct, actionable answers. Prefer commands over explanations. \
Use code blocks for commands. Never invent package names — only use packages \
that exist in the Arch/CachyOS repos or AUR."

# Parse --model override
MODEL=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --model|-m) MODEL="\$2"; shift 2 ;;
    *) break ;;
  esac
done

if [[ \$# -gt 0 ]]; then
  PROMPT="\$*"
elif [[ ! -t 0 ]]; then
  PROMPT=\$(cat)
else
  echo "Usage: ask \"question\"  or  echo \"question\" | ask" >&2; exit 1
fi

# Smart dispatch: classify with router if available, else use primary
if [[ -z "\${MODEL}" && "\${ROUTER}" != "none" && -n "\${ROUTER}" ]]; then
  CATEGORY=\$(ollama run "\${ROUTER}" \
    --system "Classify the query into ONE word: QUICK, CODE, or DEBUG. Reply with only that word." \
    "\${PROMPT}" 2>/dev/null | tr -d '[:space:]' | head -c 10)
  case "\${CATEGORY^^}" in
    QUICK) MODEL="\${ROUTER}" ;;   # fast model handles simple lookups
    *)     MODEL="\${PRIMARY}" ;;  # CODE and DEBUG go to the specialist
  esac
else
  MODEL="\${MODEL:-\${PRIMARY}}"
fi

ollama run "\${MODEL}" --system "\${SYSTEM}" "\${PROMPT}"
ASKEOF
  sudo chmod +x /usr/local/bin/ask

  # Persist env for fish and bash
  mkdir -p ~/.config/fish/conf.d
  cat > ~/.config/fish/conf.d/ollama.fish << FISHEOF
set -gx LOCAL_LLM_MODEL "${PRIMARY_MODEL}"
set -gx LOCAL_LLM_ROUTER "${ROUTER_MODEL}"
# Offline sysadmin assistant:
#   ask "how do I configure a static IP with nmcli?"
#   journalctl -xe | ask
#   dmesg | ask "any GPU errors here?"
#   ask --model ${PRIMARY_MODEL} "complex question"
FISHEOF
  grep -q 'LOCAL_LLM_MODEL' ~/.bashrc 2>/dev/null || \
    echo "export LOCAL_LLM_MODEL='${PRIMARY_MODEL}'" >> ~/.bashrc

  echo "✅  Local LLM ready."
  echo "     Primary model : ${PRIMARY_MODEL}"
  [[ "${ROUTER_MODEL}" != "none" ]] && \
    echo "     Router model  : ${ROUTER_MODEL} (handles QUICK queries fast)"
  echo "     Usage: ask \"how do I configure X\""
  echo "            journalctl -xe | ask"
  echo "            dmesg | ask \"any GPU errors?\""
}
setup_local_llm

# ── 7. Enable remaining services ──────────────────────────────
echo "── Enabling services ──"
if curl -fsSL "${DOTFILES}/services.txt" -o /tmp/services.txt 2>/dev/null; then
  grep -vE '^\s*#|^\s*$' /tmp/services.txt \
    | xargs -r -I{} sudo systemctl enable --now {} 2>/dev/null || true
fi

# ── 8. Dotfiles ───────────────────────────────────────────────
echo "── Applying dotfiles ──"
mkdir -p ~/.config/fish ~/.config/nvim ~/.ssh
curl -fsSL "${DOTFILES}/config/fish/config.fish" -o ~/.config/fish/config.fish 2>/dev/null || true
curl -fsSL "${DOTFILES}/config/nvim/init.lua"    -o ~/.config/nvim/init.lua    2>/dev/null || true
curl -fsSL "${DOTFILES}/config/ssh/config"       -o ~/.ssh/config              2>/dev/null || true
chmod 600 ~/.ssh/config 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════╗"
echo "║   ✅  Init complete                                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo
echo "  Local IP    : $(hostname -I 2>/dev/null | awk '{print $1}')"
echo "  Tailscale   : $(tailscale ip -4 2>/dev/null || echo 'check: tailscale ip')"
echo "  SSH user    : $(whoami)"
echo "  WiFi (8812) : $(lsmod 2>/dev/null | grep -q '^8812au' && echo 'AWUS036ACH ready' || echo 'check: lsmod | grep 8812au')"
echo "  GPU driver  : $(lsmod 2>/dev/null | grep -q '^nvidia ' && echo 'nvidia loaded' || (lsmod 2>/dev/null | grep -q '^amdgpu' && echo 'amdgpu loaded' || echo 'reboot to activate — driver installed'))"
echo "  Local LLM   : $(ollama list 2>/dev/null | awk 'NR>1{print $1}' | head -1 | grep -q . && echo "$(ollama list 2>/dev/null | awk 'NR>1{print $1}' | paste -sd, -) — try: ask \"hello\"" || echo 'check: ollama list')"
echo "  Claude Code : $(claude --version 2>/dev/null || echo 'run: claude --version')"
echo
echo "  Continue from another device on your tailnet:"
echo "    ssh $(whoami)@$(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>')   then   claude"
echo
