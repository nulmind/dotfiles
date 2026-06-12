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
# Decision tree: GPU VRAM → CPU RAM → tiny fallback.
# Exact quant tags chosen per hardware for best quality/VRAM balance.
# GPU path: router (qwen2.5:7b-q4_K_M) stays always-hot; specialist dispatched per query.
# Set LOCAL_LLM_MODEL / LOCAL_LLM_ROUTER in .env to override.
# Set SKIP_LLM=1 to skip entirely (pull models later when disk is ready).

# ── Model registry: tag → download size in GiB ─────────────────
declare -A LLM_TAGS=(
  # GPU ≥30GB (RTX 5090): qwen3:32b — best tool-use + hybrid thinking mode; 34 tok/s on RTX 4090
  # Qwen3-Coder-Next 80B (58.7% SWE-bench) needs 48GB VRAM+RAM — too large for single GPU
  [gpu_large_primary]="qwen3:32b-q4_K_M"
  [gpu_large_primary_sz]=20
  # GPU ≥22GB (RTX 3090): qwen2.5-coder:32b — best raw coding benchmark (HumanEval 92.7%)
  [gpu_mid_primary]="qwen2.5-coder:32b-instruct-q4_K_M"
  [gpu_mid_primary_sz]=20
  # GPU ≥10GB: gemma4:12b-it-qat — QAT beats standard Q4_K_M at ~7GB; multimodal, 256K ctx
  # QAT (Quantization-Aware Training) bakes compression into training; ~72% mem reduction, near-original quality
  [gpu_small_primary]="gemma4:12b-it-qat"
  [gpu_small_primary_sz]=7
  # GPU router: always-hot classifier, tiny footprint
  [gpu_router]="qwen2.5:7b-instruct-q4_K_M"
  [gpu_router_sz]=5
  # CPU ≥80GB RAM: gemma4:12b-it-qat — 7GB vs 16GB for deepseek q8, faster inference, QAT quality
  [cpu_large_primary]="gemma4:12b-it-qat"
  [cpu_large_primary_sz]=7
  # CPU ≥48GB RAM: phi4 Q4_K_M — best reasoning/math at 14B on CPU
  [cpu_mid_primary]="phi4:14b-q4_K_M"
  [cpu_mid_primary_sz]=9
  # CPU ≥14GB RAM: qwen2.5-coder Q5_K_M — step up from Q4 worth it at 7B
  [cpu_small_primary]="qwen2.5-coder:7b-instruct-q5_K_M"
  [cpu_small_primary_sz]=5
  # Fallback: phi4-mini Q4_K_M — retains full 128K ctx (Q8/fp16 reduce to 4K)
  [fallback_primary]="phi4-mini:3.8b-q4_K_M"
  [fallback_primary_sz]=3
)

_llm_pick_model() {
  # Returns: PRIMARY_TAG  ROUTER_TAG  REASON
  local vram_mb=0 ram_gb=0

  if command -v nvidia-smi &>/dev/null; then
    vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits \
              2>/dev/null | head -1 | tr -d ' ')
    vram_mb="${vram_mb:-0}"
  fi
  ram_gb=$(awk '/^MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)

  if (( vram_mb >= 30000 )); then
    echo "${LLM_TAGS[gpu_large_primary]} ${LLM_TAGS[gpu_router]} GPU≥30GB→qwen3:32b+router"
  elif (( vram_mb >= 22000 )); then
    echo "${LLM_TAGS[gpu_mid_primary]} ${LLM_TAGS[gpu_router]} GPU≥22GB→qwen2.5-coder:32b+router"
  elif (( vram_mb >= 10000 )); then
    echo "${LLM_TAGS[gpu_small_primary]} ${LLM_TAGS[gpu_router]} GPU≥10GB→gemma4:12b-qat+router"
  elif (( ram_gb >= 80 )); then
    echo "${LLM_TAGS[cpu_large_primary]} none RAM≥80GB→gemma4:12b-qat"
  elif (( ram_gb >= 48 )); then
    echo "${LLM_TAGS[cpu_mid_primary]} none RAM≥48GB→phi4:14b-q4_K_M"
  elif (( ram_gb >= 14 )); then
    echo "${LLM_TAGS[cpu_small_primary]} none RAM≥14GB→qwen2.5-coder:7b-q5_K_M"
  else
    echo "${LLM_TAGS[fallback_primary]} none fallback→phi4-mini:3.8b-q4_K_M"
  fi
}

_llm_check_disk() {
  local primary_sz="$1" router_sz="$2"
  local needed=$(( primary_sz + router_sz + 10 )) free_gb
  local models_path="${OLLAMA_MODELS:-/usr/share/ollama/.ollama/models}"
  # Fall back to checking /var if models path doesn't exist yet
  free_gb=$(df -BG "${models_path}" 2>/dev/null \
            | awk 'NR==2{gsub(/G/,"",$4); print $4}') \
    || free_gb=$(df -BG /var 2>/dev/null | awk 'NR==2{gsub(/G/,"",$4); print $4}') \
    || free_gb=0
  if (( free_gb < needed )); then
    echo "⚠️   Disk space: need ~${needed}GB free for models, only ${free_gb}GB available."
    echo "   To fix:"
    echo "     • Plug in a larger drive and add to .env:"
    echo "         OLLAMA_MODELS=/mnt/bigdrive/.ollama/models"
    echo "     • Or use a smaller model: LOCAL_LLM_MODEL=phi4-mini:3.8b-q4_K_M"
    echo "     • Or skip for now: SKIP_LLM=1 (pull models manually later)"
    return 1
  fi
  return 0
}

_llm_write_modelfile() {
  # Create an Ollama Modelfile tuned for the detected hardware scenario
  local tag="$1" is_gpu="$2" is_router="$3"
  local mfile="/tmp/ollama-modelfile-$(echo "${tag}" | tr ':/' '--')"
  local num_ctx=8192 temp=0.3 gpu_layers=99 num_thread=0

  # Context window: GPU has VRAM headroom with KV quant; CPU keep smaller
  [[ "${is_gpu}" == "1" ]] && num_ctx=8192 || num_ctx=4096
  # Router uses tiny context — it only classifies short queries
  [[ "${is_router}" == "1" ]] && num_ctx=2048 && temp=0.1
  # Thread count: physical cores only (hyperthreads hurt LLM inference)
  num_thread=$(nproc --all 2>/dev/null || echo 8)
  local phys_cores
  phys_cores=$(lscpu 2>/dev/null | awk '/^Core\(s\) per socket/{c=$NF} /^Socket\(s\)/{s=$NF} END{print c*s}')
  [[ -n "${phys_cores}" && "${phys_cores}" -gt 0 ]] && num_thread="${phys_cores}"

  {
    echo "FROM ${tag}"
    echo "PARAMETER num_ctx ${num_ctx}"
    echo "PARAMETER num_predict -1"
    echo "PARAMETER temperature ${temp}"
    echo "PARAMETER repeat_penalty 1.05"
    if [[ "${is_gpu}" == "1" ]]; then
      echo "PARAMETER num_gpu ${gpu_layers}"
    else
      echo "PARAMETER num_gpu 0"
      echo "PARAMETER num_thread ${num_thread}"
    fi
  } > "${mfile}"
  echo "${mfile}"
}

setup_local_llm() {
  if [[ -n "${SKIP_LLM:-}" ]]; then
    echo "── Local LLM skipped (SKIP_LLM set) ──"; return 0
  fi
  echo "── Setting up local LLM (Ollama) ──"

  # Detect hardware scenario
  local PRIMARY_MODEL ROUTER_MODEL REASON IS_GPU=0
  if [[ -n "${LOCAL_LLM_MODEL:-}" ]]; then
    PRIMARY_MODEL="${LOCAL_LLM_MODEL}"
    ROUTER_MODEL="${LOCAL_LLM_ROUTER:-none}"
    REASON="override from .env"
  else
    read -r PRIMARY_MODEL ROUTER_MODEL REASON <<< "$(_llm_pick_model)"
  fi
  [[ "${PRIMARY_MODEL}" == *"q4_K_M"* || "${PRIMARY_MODEL}" == *"q5_K_M"* \
     || "${PRIMARY_MODEL}" == *"q8_0"* ]] || true  # tag always has quant suffix now
  command -v nvidia-smi &>/dev/null && (( $(nvidia-smi --query-gpu=memory.total \
    --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ') > 8000 )) \
    && IS_GPU=1 || true

  echo "   Hardware : $(command -v nvidia-smi &>/dev/null && nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "CPU-only ($(awk '/^MemTotal/{printf "%dGB", $2/1024/1024}' /proc/meminfo))")"
  echo "   Primary  : ${PRIMARY_MODEL} (${REASON})"
  [[ "${ROUTER_MODEL}" != "none" ]] && echo "   Router   : ${ROUTER_MODEL} (always-hot, handles QUICK queries)"

  # Sizes for disk check
  local p_sz r_sz=0
  p_sz=$(echo "${PRIMARY_MODEL}" | grep -oP '\d+(?=b[-:]|b$)' | tail -1 || echo 10)
  # Rough size estimate from param count if not in registry
  (( p_sz > 30 )) && p_sz=20 || (( p_sz > 10 )) && p_sz=9 || p_sz=5
  [[ "${ROUTER_MODEL}" != "none" ]] && r_sz=5

  if ! _llm_check_disk "${p_sz}" "${r_sz}"; then
    echo "   Skipping — fix disk space and re-run, or set SKIP_LLM=1."
    return 0
  fi

  # Install Ollama
  if ! command -v ollama &>/dev/null; then
    echo "   Installing Ollama..."
    curl -fsSL https://ollama.ai/install.sh | sh
  else
    echo "   Ollama $(ollama --version 2>/dev/null) already installed."
  fi

  # Ollama systemd config: Flash Attention + KV cache quant on NVIDIA,
  # correct parallelism for CPU-only
  sudo mkdir -p /etc/systemd/system/ollama.service.d
  if [[ "${IS_GPU}" == "1" ]]; then
    sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_MAX_LOADED_MODELS=3"
Environment="OLLAMA_KEEP_ALIVE=60m"
Environment="OLLAMA_NUM_PARALLEL=2"
EOF
  else
    sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=1"
EOF
  fi
  sudo systemctl daemon-reload
  sudo systemctl enable --now ollama 2>/dev/null || true

  # Wait for API
  local tries=0
  until curl -sf http://localhost:11434/api/tags &>/dev/null || (( ++tries >= 30 )); do
    sleep 1
  done
  if (( tries >= 30 )); then
    echo "⚠️   Ollama API not responding — run manually: ollama pull ${PRIMARY_MODEL}"
    return 0
  fi

  # Pull and register models with tuned Modelfiles
  _llm_pull_and_create() {
    local tag="$1" is_router="${2:-0}"
    local short_name="${tag%%:*}"
    local create_name="${tag//:/-}"   # ollama create name (no colons)

    if ollama list 2>/dev/null | grep -qF "${tag}"; then
      echo "   ${tag}: already present."
    else
      echo "   Pulling ${tag}..."
      ollama pull "${tag}"
    fi

    # Create a named model with tuned parameters
    local mfile
    mfile=$(_llm_write_modelfile "${tag}" "${IS_GPU}" "${is_router}")
    ollama create "${create_name}-tuned" -f "${mfile}" &>/dev/null || true
  }

  _llm_pull_and_create "${PRIMARY_MODEL}" 0
  [[ "${ROUTER_MODEL}" != "none" ]] && _llm_pull_and_create "${ROUTER_MODEL}" 1

  # Keep router always-hot: set its keep-alive to indefinite via API
  if [[ "${ROUTER_MODEL}" != "none" ]]; then
    local router_create_name="${ROUTER_MODEL//:/-}-tuned"
    curl -sf http://localhost:11434/api/generate \
      -d "{\"model\":\"${router_create_name}\",\"keep_alive\":-1,\"prompt\":\"hi\"}" \
      &>/dev/null || true
  fi

  # Write /usr/local/bin/ask with smart dispatch
  sudo mkdir -p /usr/local/bin
  local _primary="${PRIMARY_MODEL}" _router="${ROUTER_MODEL}"
  local _primary_tuned="${PRIMARY_MODEL//:/-}-tuned"
  local _router_tuned="${ROUTER_MODEL//:/-}-tuned"

  sudo tee /usr/local/bin/ask > /dev/null << ASKEOF
#!/usr/bin/env bash
# ask — offline sysadmin LLM assistant (auto-dispatches to best local model)
# Usage:  ask "how do I configure X"
#         journalctl -xe | ask
#         dmesg | ask "any GPU errors?"
#         ask --model <name> "question"

PRIMARY="${_primary_tuned}"
ROUTER="${_router_tuned}"
SYSTEM="You are a concise Linux/Arch/CachyOS sysadmin assistant. \
Give direct, actionable answers. Prefer commands over explanations. \
Use code blocks for commands. Never invent package names — only use packages \
that exist in the Arch/CachyOS repos or AUR."

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
  echo "Usage: ask \"question\"  or  command | ask" >&2; exit 1
fi

if [[ -z "\${MODEL}" && "\${ROUTER}" != "none-tuned" && -n "\${ROUTER}" ]]; then
  CATEGORY=\$(ollama run "\${ROUTER}" \
    --system "Reply with ONE word only — QUICK, CODE, or DEBUG — classifying this query." \
    "\${PROMPT}" 2>/dev/null | tr -d '[:space:]\n' | head -c 10)
  case "\${CATEGORY^^}" in
    QUICK) MODEL="\${ROUTER}" ;;
    *)     MODEL="\${PRIMARY}" ;;
  esac
else
  MODEL="\${MODEL:-\${PRIMARY}}"
fi

ollama run "\${MODEL}" --system "\${SYSTEM}" "\${PROMPT}"
ASKEOF
  sudo chmod +x /usr/local/bin/ask

  mkdir -p ~/.config/fish/conf.d
  cat > ~/.config/fish/conf.d/ollama.fish << FISHEOF
set -gx LOCAL_LLM_MODEL "${PRIMARY_MODEL}"
set -gx LOCAL_LLM_ROUTER "${ROUTER_MODEL}"
# Offline sysadmin assistant — examples:
#   ask "how do I set a static IP with nmcli?"
#   journalctl -xe | ask
#   dmesg | ask "any GPU or driver errors?"
#   cat /etc/fstab | ask "explain each mount option"
FISHEOF
  grep -q 'LOCAL_LLM_MODEL' ~/.bashrc 2>/dev/null || \
    printf 'export LOCAL_LLM_MODEL="%s"\nexport LOCAL_LLM_ROUTER="%s"\n' \
      "${PRIMARY_MODEL}" "${ROUTER_MODEL}" >> ~/.bashrc

  echo "✅  Local LLM ready."
  echo "     Primary  : ${PRIMARY_MODEL}"
  [[ "${ROUTER_MODEL}" != "none" ]] && echo "     Router   : ${ROUTER_MODEL}"
  echo "     Examples : ask \"how do I configure X\""
  echo "                journalctl -xe | ask"
  echo "                dmesg | ask \"any GPU errors?\""
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
