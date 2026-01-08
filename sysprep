#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

# --- STEP 1: Rename the OS ---
echo "### STEP 1: RENAME OS ###"
current_host=$(hostname)
read -p "Enter new hostname (Current: $current_host): " NEW_HOSTNAME
if [ -n "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
fi

# --- STEP 2: Uninstall & Deep Clean ---
echo "### STEP 2: UNINSTALL & CLEAN ###"
mapfile -t PACKAGE_LIST < <(apt-mark showmanual | grep -vE '^(linux-|ubuntu-|grub|systemd|lib|gir1\.2|fonts-|gnome-|snapd|base-|bash|dash|zsh|grep|gzip|tar|coreutils|util-linux|findutils|diffutils|hostname|init|ncurses|python|cloud-init|openssh|e2fsprogs|fdisk|bsdutils|mount|login|passwd|procps|sysvinit|net-tools|xe-guest-utilities)')

if [ ${#PACKAGE_LIST[@]} -gt 0 ]; then
    apt-get remove --purge -y --allow-change-held-packages "${PACKAGE_LIST[@]}"
fi

# Purge Snaps
for s in $(snap list | awk '{print $1}' | tail -n +2); do snap remove "$s" 2>/dev/null; done
apt-get purge -y snapd

# Deep Clean APT and Unattended-Upgrades noise
apt-get purge -y $(dpkg -l | grep '^rc' | awk '{print $2}') 2>/dev/null
apt-get autoremove --purge -y
apt-get clean
rm -rf /var/lib/apt/periodic/*
rm -rf /var/log/unattended-upgrades/*

# --- STEP 3: User Management & File Scrubbing ---
echo "### STEP 3: USER SCRUBBING ###"
HUMAN_USERS=$(awk -F: '$3 >= 1000 && $3 <= 60000 {print $1}' /etc/passwd)
for user in $HUMAN_USERS; do
    pkill -9 -u "$user" 2>/dev/null
    sleep 1
    deluser --remove-all-files "$user" 2>/dev/null
done

read -p "Enter name for the new sudo user: " NEW_USER
if [ -n "$NEW_USER" ]; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
    chmod 0440 "/etc/sudoers.d/$NEW_USER"
    
    if [ -d "/root/.ssh" ]; then
        mkdir -p "/home/$NEW_USER/.ssh"
        cp -r /root/.ssh/* "/home/$NEW_USER/.ssh/"
        chown -R "$NEW_USER:$NEW_USER" "/home/$NEW_USER/.ssh"
        chmod 700 "/home/$NEW_USER/.ssh"
    fi
fi

# --- STEP 4: Root Home & System Shrink ---
echo "### STEP 4: ROOT HOME & SYSTEM SHRINK ###"

# Clean Root Home - Leaves only SSH and basic profiles
find /root -maxdepth 1 ! -name "." ! -name ".ssh" ! -name ".bashrc" ! -name ".profile" ! -name "sysprep.sh" -exec rm -rf {} +

# Resize Swap to 1GB
swapoff -a && rm -f /swap.img
sed -i '/swap\.img/d' /etc/fstab
fallocate -l 1G /swap.img && chmod 600 /swap.img && mkswap /swap.img
echo '/swap.img none swap sw 0 0' >> /etc/fstab

# Generalization
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/udev/rules.d/70-persistent-net.rules

# Clear "Last Login" and Upgrade log noise
echo > /var/log/wtmp
echo > /var/log/btmp
echo > /var/log/lastlog
journalctl --vacuum-time=1s
find /var/log -type f -exec truncate -s 0 {} \;

echo "---------------------------------------------"
echo "Scrub complete. Removing script and powering off..."
rm -f /root/sysprep.sh
cat /dev/null > ~/.bash_history && history -c
sleep 2
shutdown -h now
