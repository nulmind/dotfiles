# CachyOS bootdrive + first-boot dotfiles

Two double-clickable macOS scripts to make a bootable CachyOS USB, plus a
GitHub-hosted `init.sh` to configure the machine on first boot (network → SSH
→ Tailscale → Claude Code → dotfiles), including the **AWUS036ACH** WiFi driver.

## On macOS — make the USB

1. Double-click **`1_download_cachyos.command`** — downloads the ISO to `~/Downloads`
   (skips if already present).
2. Double-click **`2_flash_usb.command`** — pick your USB from the numbered list,
   type `YES` then `FLASH` to confirm. Nothing is erased before both confirmations.

`dd` writes to the raw device (`/dev/rdiskN`) for speed. No Ventoy, no persistence —
a plain bootable ISO that works on both AMD and Intel x86_64 hardware.

> If double-click is blocked, run once in Terminal: `chmod +x ~/Desktop/*.command`

## On first CachyOS boot — configure the machine

1. Put this folder in a **private** GitHub repo and edit the `DOTFILES` URL at the
   top of `init.sh`.
2. Copy `.env.example` → `.env` and set `HOTSPOT_PASS` (git-ignored; never committed).
3. From the live session:
   ```
   curl -fsSL https://raw.githubusercontent.com/YOU/dotfiles/main/init.sh | bash
   ```

`init.sh` is idempotent and fail-fast. Network is tried in order:
already-online → static Ethernet → iPhone hotspot → manual WiFi.

### AWUS036ACH (Realtek RTL8812AU)

`setup_awus036ach()` installs `dkms` + kernel headers and the `rtl8812au-dkms-git`
driver (repo → AUR via paru/yay → source build fallback), then loads `8812au`.
Verify after boot: `lsmod | grep 8812au` and `nmcli device` shows the adapter.

## Tests

```
bash tests/test_network_logic.sh
```

Mocks `ping`/`nmcli` and asserts `setup_network()` takes the right path in all
five scenarios (already-online, static-ethernet, hotspot-after-eth-fail,
hotspot-no-eth, manual-wifi fallback). No hardware required.

## Layout

```
init.sh                     entry point (curl on first boot)
packages.txt                pacman packages, one per line
services.txt                systemd units to enable
.env.example                secrets template (copy to .env)
.gitignore                  ignores .env
config/fish/config.fish
config/nvim/init.lua
config/ssh/config
tests/test_network_logic.sh
```
