#!/bin/bash
# beholder-recon.sh — Hardware & software reconnaissance for Beholder Pi
# Run on the target Pi: bash beholder-recon.sh

set -euo pipefail

divider() {
  echo ""
  echo "========================================"
  echo "  $1"
  echo "========================================"
}

divider "HOSTNAME & IDENTITY"
hostname
cat /etc/hostname 2>/dev/null || true
cat /etc/machine-id 2>/dev/null || true

divider "OS & KERNEL"
cat /etc/os-release 2>/dev/null || true
uname -a
cat /proc/version 2>/dev/null || true

divider "RASPBERRY PI MODEL"
cat /proc/device-tree/model 2>/dev/null && echo "" || echo "Not a Pi or model file missing"
cat /proc/cpuinfo | grep -E "^(model name|Hardware|Revision|Serial|Model)" || true

divider "CPU"
lscpu 2>/dev/null || cat /proc/cpuinfo
nproc

divider "MEMORY"
free -h
cat /proc/meminfo | head -5

divider "STORAGE"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE 2>/dev/null || lsblk
df -h
cat /etc/fstab 2>/dev/null || true

divider "GPU / VIDEO"
vcgencmd get_mem gpu 2>/dev/null || echo "vcgencmd not available"
vcgencmd get_config int 2>/dev/null | grep -i "gpu\|hdmi\|display" || true
ls /dev/video* 2>/dev/null && echo "Camera devices found" || echo "No /dev/video* devices"
libcamera-hello --list-cameras 2>/dev/null || echo "libcamera not available or no cameras"
v4l2-ctl --list-devices 2>/dev/null || true

divider "USB DEVICES"
lsusb 2>/dev/null || echo "lsusb not available"

divider "I2C / SPI / GPIO"
ls /dev/i2c-* 2>/dev/null && echo "I2C enabled" || echo "No I2C devices"
ls /dev/spidev* 2>/dev/null && echo "SPI enabled" || echo "No SPI devices"
cat /boot/config.txt 2>/dev/null | grep -v "^#" | grep -v "^$" || \
  cat /boot/firmware/config.txt 2>/dev/null | grep -v "^#" | grep -v "^$" || \
  echo "No config.txt found"
raspi-gpio get 2>/dev/null | head -20 || true

divider "NETWORK"
ip -br addr 2>/dev/null || ifconfig 2>/dev/null
ip -br link 2>/dev/null || true
iwconfig 2>/dev/null 2>&1 | grep -v "no wireless" || true
cat /etc/wpa_supplicant/wpa_supplicant.conf 2>/dev/null | grep -v "psk" || true
ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || true

divider "BLUETOOTH"
hciconfig 2>/dev/null || echo "No bluetooth adapter"
bluetoothctl show 2>/dev/null || true

divider "AUDIO"
aplay -l 2>/dev/null || echo "No audio playback devices"
arecord -l 2>/dev/null || echo "No audio capture devices"
pactl info 2>/dev/null || pulseaudio --check 2>/dev/null && echo "PulseAudio running" || true
pipewire --version 2>/dev/null || true

divider "DISPLAY / DESKTOP"
echo "DISPLAY=$DISPLAY" 2>/dev/null || echo "DISPLAY not set"
echo "XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-not set}"
echo "WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-not set}"
dpkg -l | grep -E "xserver|wayland|lxde|lxqt|pixel|desktop" 2>/dev/null | head -10 || true

divider "DOCKER"
docker --version 2>/dev/null || echo "Docker not installed"
docker ps -a 2>/dev/null || true
docker images 2>/dev/null || true

divider "INSTALLED PACKAGES (key)"
for pkg in python3 python3-pip node npm nginx apache2 mosquitto \
           homeassistant zigbee2mqtt ffmpeg vlc pihole; do
  if dpkg -s "$pkg" &>/dev/null; then
    echo "[installed] $pkg $(dpkg -s "$pkg" | grep Version | head -1)"
  elif command -v "$pkg" &>/dev/null; then
    echo "[available] $pkg ($(command -v "$pkg"))"
  fi
done

divider "PYTHON ENVIRONMENT"
python3 --version 2>/dev/null || true
pip3 list 2>/dev/null | head -30 || true

divider "SYSTEMD SERVICES (enabled)"
systemctl list-unit-files --state=enabled --type=service 2>/dev/null | grep -v "^$" || true

divider "SYSTEMD SERVICES (running)"
systemctl list-units --type=service --state=running 2>/dev/null | grep -v "^$" || true

divider "CRON JOBS"
crontab -l 2>/dev/null || echo "No crontab for $(whoami)"
ls /etc/cron.d/ 2>/dev/null || true

divider "TEMPERATURE & THROTTLING"
vcgencmd measure_temp 2>/dev/null || cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "No temp sensor"
vcgencmd get_throttled 2>/dev/null || true

divider "UPTIME & LOAD"
uptime
cat /proc/loadavg

divider "USERS"
who
cat /etc/passwd | grep -E ":/home/" | cut -d: -f1,6,7

divider "SSH CONFIG"
ls -la ~/.ssh/ 2>/dev/null || echo "No .ssh directory"
cat /etc/ssh/sshd_config 2>/dev/null | grep -E "^(Port|PermitRoot|PasswordAuth|PubkeyAuth)" || true

divider "HAT / OVERLAY DETECTION"
cat /proc/device-tree/hat/product 2>/dev/null && echo "" || echo "No HAT detected"
cat /proc/device-tree/hat/vendor 2>/dev/null && echo "" || true
dtoverlay -l 2>/dev/null || true

divider "RECON COMPLETE"
echo "Paste the output of this script and we'll build Beholder's stack."
