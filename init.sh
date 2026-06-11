#!/usr/bin/env bash
#
# init.sh — CachyOS live-environment bootstrap
# --------------------------------------------
# Curl this down on first boot:
#   curl -fsSL https://raw.githubusercontent.com/YOU/dotfiles/main/init.sh | bash
#
# Order is deliberate so you can hand off to remote/agent config early:
#   network → packages → AWUS036ACH driver → SSH → Tailscale → Claude Code → dotfiles
#
# Idempotent: safe to re-run. Fail-fast: a failed step stops the script.

set -euo pipefail

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
  mapfile -t PKGS < <(grep -vE '^\s*#|^\s*$' /tmp/packages.txt)
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
echo "  Claude Code : $(claude --version 2>/dev/null || echo 'run: claude --version')"
echo
echo "  Continue from another device on your tailnet:"
echo "    ssh $(whoami)@$(tailscale ip -4 2>/dev/null || echo '<tailscale-ip>')   then   claude"
echo
