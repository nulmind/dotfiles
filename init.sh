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
# Runs entirely on the local GPU — no internet needed after setup.
# Model is pulled now (while online) so it's cached for offline use.
# Override model with: LOCAL_LLM_MODEL=llama3.3:70b bash init.sh
LOCAL_LLM_MODEL="${LOCAL_LLM_MODEL:-qwen2.5:14b}"

setup_local_llm() {
  echo "── Setting up local LLM (Ollama + ${LOCAL_LLM_MODEL}) ──"

  # Install Ollama via its official installer (handles arch + GPU detection)
  if ! command -v ollama &>/dev/null; then
    echo "   Installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh
  else
    echo "   Ollama already installed: $(ollama --version 2>/dev/null)"
  fi

  # Enable and start the Ollama service
  sudo systemctl enable --now ollama 2>/dev/null || true

  # Wait for the API to be ready (up to 30s)
  local tries=0
  until curl -sf http://localhost:11434/api/tags &>/dev/null || (( ++tries >= 30 )); do
    sleep 1
  done
  if (( tries >= 30 )); then
    echo "⚠️   Ollama API not responding — skipping model pull. Run: ollama pull ${LOCAL_LLM_MODEL}"
    return 0
  fi

  # Pull the model (cached on disk — works offline after this)
  if ollama list 2>/dev/null | grep -q "^${LOCAL_LLM_MODEL}"; then
    echo "   Model ${LOCAL_LLM_MODEL} already present."
  else
    echo "   Pulling ${LOCAL_LLM_MODEL} (this downloads ~9 GB once, then works offline)..."
    ollama pull "${LOCAL_LLM_MODEL}"
  fi

  # Install the 'ask' helper: `ask "how do I configure X"`
  sudo mkdir -p /usr/local/bin
  sudo tee /usr/local/bin/ask > /dev/null << 'ASKEOF'
#!/usr/bin/env bash
# ask — query the local LLM with a sysadmin system prompt
# Usage: ask "how do I list open ports?"  or  echo "what is /etc/fstab?" | ask
MODEL="${LOCAL_LLM_MODEL:-qwen2.5:14b}"
SYSTEM="You are a concise Linux/Arch sysadmin assistant running locally on CachyOS. \
Give direct, actionable answers. Prefer commands over explanations. \
When showing commands, use code blocks. Never hallucinate package names."

if [[ $# -gt 0 ]]; then
  PROMPT="$*"
elif [[ ! -t 0 ]]; then
  PROMPT=$(cat)
else
  echo "Usage: ask \"question\"  or  echo \"question\" | ask" >&2; exit 1
fi

ollama run "${MODEL}" --system "${SYSTEM}" "${PROMPT}"
ASKEOF
  sudo chmod +x /usr/local/bin/ask

  # Fish shell alias + model env var
  mkdir -p ~/.config/fish/conf.d
  cat > ~/.config/fish/conf.d/ollama.fish << FISHEOF
set -gx LOCAL_LLM_MODEL "${LOCAL_LLM_MODEL}"
# 'ask' is in /usr/local/bin — no alias needed, just a reminder:
# ask "how do I configure a static IP with nmcli?"
FISHEOF

  echo "✅  Local LLM ready. Usage:"
  echo "     ask \"how do I configure a static IP?\""
  echo "     ask \"show me the nvidia-smi output format\""
  echo "     journalctl -xe | ask   # pipe logs for analysis"
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
echo "  Local LLM   : $(ollama list 2>/dev/null | grep -q "${LOCAL_LLM_MODEL}" && echo "${LOCAL_LLM_MODEL} ready — try: ask \"hello\"" || echo 'check: ollama list')"
echo "  Claude Code : $(claude --version 2>/dev/null || echo 'run: claude --version')"
echo
echo "  Continue from another device on your tailnet:"
echo "    ssh $(whoami)@$(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>')   then   claude"
echo
