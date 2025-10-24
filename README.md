# fydeos_portable_setup

Safety reminder

Edit variables at top of extra.sh (especially USB_PERSIST_DEV, USB_BOOT_DEV) before running destructive tasks (luks, restore).

Always run verify first to see missing dependencies.

Keep a rescue USB image and backups.

fydeos_portable_setup.sh
#!/bin/bash
# fydeos_portable_setup.sh — bootstrap & optimization for FydeOS live USB
# Author: Dinadeyohvsgi (adjust as needed)
# Usage: On boot, Ctrl+Alt+T → shell → sudo -i → run this script

below are two ready-to-run bootstrap options. Both will fetch the repo, make the important scripts executable, and run the script’s safe verify action. Pick one (git clone is preferred). After that I show quick follow-ups (edit variables, run components, view logs).

Option A — Recommended (git clone)
# clone, adjust perms, run non-destructive verification
git clone https://github.com/CosmicIndustries/fydeos_portable_setup.git ~/fydeos_portable_setup
cd ~/fydeos_portable_setup
chmod +x extra.sh enable_usb_persistence.sh fydeos_portable_setup.sh || true
sudo ./extra.sh verify

Option B — No git (curl + tar)
# download repository tarball, extract, run verification
curl -L https://github.com/CosmicIndustries/fydeos_portable_setup/archive/refs/heads/main.tar.gz | tar xz
mv fydeos_portable_setup-main ~/fydeos_portable_setup
cd ~/fydeos_portable_setup
chmod +x extra.sh enable_usb_persistence.sh fydeos_portable_setup.sh || true
sudo ./extra.sh verify

git clone https://github.com/CosmicIndustries/fydeos_portable_setup.git ~/fydeos_portable_setup && cd ~/fydeos_portable_setup && chmod +x extra.sh enable_usb_persistence.sh fydeos_portable_setup.sh || true && sudo ./extra.sh verify


Afterverify — quick next commands

Edit variables before running destructive tasks (LUKS, imaging):
# open and edit in nano or your preferred editor
nano ~/fydeos_portable_setup/extra.sh

Run a specific component (safe verify done first):
# encrypt persistence (DESTRUCTIVE) — only after editing variables and backups
cd ~/fydeos_portable_setup
sudo ./extra.sh luks

# mount overlay
sudo ./extra.sh overlay

# enable zram now
sudo ./extra.sh zram


View the script log (helps debug failures):
sudo tail -n 200 /var/log/extra_sh.log


curl -L -o ~/fydeos_portable_setup/extra.sh \
  https://raw.githubusercontent.com/CosmicIndustries/fydeos_portable_setup/main/extra.sh
chmod +x ~/fydeos_portable_setup/extra.sh
sudo ~/fydeos_portable_setup/extra.sh verify


