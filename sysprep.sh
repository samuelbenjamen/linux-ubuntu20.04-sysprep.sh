#!/bin/bash
#
# Ubuntu Sysprep Script - OS Generalization for Golden Image
# Compatible with Ubuntu 18.04, 20.04, 22.04, 24.04 and newer
# Must be run as root
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print colored messages
print_header() {
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}============================================================================${NC}"
}

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   print_error "This script must be run as root"
   exit 1
fi

clear
print_header "Ubuntu Sysprep - OS Generalization Script"
echo ""

# Detect Ubuntu version
UBUNTU_VERSION=$(lsb_release -rs 2>/dev/null || echo "Unknown")
print_info "Detected Ubuntu version: $UBUNTU_VERSION"
print_info "This script will prepare your cloned VM for reuse"
echo ""

# ============================================================================
# PHASE 1: CONFIGURATION (Collect all inputs)
# ============================================================================
print_header "CONFIGURATION PHASE - Please answer all questions"
echo ""

# ---------- QUESTION 1: Hostname ----------
CURRENT_HOSTNAME=$(hostname)
print_info "Current hostname: $CURRENT_HOSTNAME"
echo ""

while true; do
    read -p "Enter new hostname for this system: " NEW_HOSTNAME
    
    if [[ -z "$NEW_HOSTNAME" ]]; then
        print_error "Hostname cannot be empty. Please try again."
        continue
    fi
    
    # Validate hostname format (RFC 1123)
    if ! [[ "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
        print_error "Invalid hostname format. Must be alphanumeric with hyphens (max 63 chars)"
        continue
    fi
    break
done
echo ""

# ---------- QUESTION 2: Package Selection ----------
print_info "Gathering manually installed packages..."
echo ""

# Check if initial-status.gz exists (may not exist on newer versions)
if [[ -f /var/log/installer/initial-status.gz ]]; then
    MANUAL_PACKAGES=$(comm -23 \
        <(apt-mark showmanual | sort) \
        <(gzip -dc /var/log/installer/initial-status.gz | sed -n 's/^Package: //p' | sort))
else
    # Fallback method
    MANUAL_PACKAGES=$(apt-mark showmanual | sort)
fi

# Filter out kernel and essential system packages
FILTERED_PACKAGES=$(echo "$MANUAL_PACKAGES" | grep -v -E '^(linux-|ubuntu-|grub|systemd|apt|dpkg|libc|gcc|g\+\+|make|perl|python3?-minimal)')

PKG_NUMS=""
if [[ -z "$FILTERED_PACKAGES" ]]; then
    print_info "No manually installed packages found to remove"
else
    print_info "Manually Installed Packages (excluding core system packages):"
    echo "================================================================"
    i=1
    declare -A PKG_MAP
    while IFS= read -r pkg; do
        if [[ -n "$pkg" ]]; then
            printf "%3d) %s\n" "$i" "$pkg"
            PKG_MAP[$i]="$pkg"
            ((i++))
        fi
    done <<< "$FILTERED_PACKAGES"
    echo ""
    
    read -p "Enter package numbers to uninstall (space-separated, or press Enter to skip): " PKG_NUMS
fi
echo ""

# ---------- QUESTION 3: User Deletion Confirmation ----------
print_warning "User Deletion Configuration:"
print_warning "This script checks for users (UID >= 1000) to delete."
print_warning "EXCEPTIONS: 'root' and 'deploy' will NEVER be touched."
echo ""

# Get list of all users with UID >= 1000, excluding 'nobody' and 'deploy'
USERS_TO_DELETE=$(awk -F: '$3 >= 1000 && $1 != "nobody" && $1 != "deploy" {print $1}' /etc/passwd)

CONFIRM_DELETE="no"
if [[ -z "$USERS_TO_DELETE" ]]; then
    print_info "No additional users found (only root and deploy exist)"
else
    print_warning "The following users will be DELETED with their home directories:"
    echo "================================================================"
    echo "$USERS_TO_DELETE" | tr '\n' ', ' | sed 's/,$/\n/'
    echo "================================================================"
    echo ""
    
    read -p "Continue with user deletion? Type 'yes' to confirm: " CONFIRM_DELETE
fi
echo ""

# ---------- FINAL CONFIRMATION ----------
print_header "CONFIGURATION SUMMARY"
echo ""
print_info "Configuration Summary:"
echo "  → New hostname: $NEW_HOSTNAME"

# Calculate selected packages string for summary
PACKAGES_TO_REMOVE=""
if [[ -n "$PKG_NUMS" ]]; then
    for num in $PKG_NUMS; do
        if [[ -n "${PKG_MAP[$num]}" ]]; then
            PACKAGES_TO_REMOVE="$PACKAGES_TO_REMOVE ${PKG_MAP[$num]}"
        fi
    done
fi
[[ -z "$PACKAGES_TO_REMOVE" ]] && PACKAGES_TO_REMOVE=" None"
echo "  → Packages to remove:$PACKAGES_TO_REMOVE"

if [[ "$CONFIRM_DELETE" == "yes" ]] && [[ -n "$USERS_TO_DELETE" ]]; then
    echo "  → Users to delete: $(echo $USERS_TO_DELETE | tr '\n' ' ')"
else
    echo "  → Users to delete: None"
fi

echo "  → Swap file: Will be reset to 1GB"
echo "  → Disk cleanup: Will remove old kernels, caches, logs, temporary files"
echo "  → OS generalization: Will reset machine-id, clear logs, remove DHCP leases"
echo "  → System action: Will REBOOT after completion"
echo ""

read -p "Proceed with sysprep? Type 'yes' to continue: " FINAL_CONFIRM

if [[ "$FINAL_CONFIRM" != "yes" ]]; then
    print_warning "Sysprep cancelled by user"
    exit 0
fi

echo ""
print_success "Configuration confirmed. Starting sysprep process..."
sleep 2
echo ""

# ============================================================================
# PHASE 2: EXECUTION (Automated)
# ============================================================================

# --- STEP 1: HOSTNAME ---
print_header "STEP 1: Hostname Configuration"
print_info "Setting hostname to: $NEW_HOSTNAME"
hostnamectl set-hostname "$NEW_HOSTNAME"

# Update /etc/hosts
if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
fi
print_success "Hostname configured"

# --- STEP 2: PACKAGES ---
print_header "STEP 2: Package Management"

# Remove selected packages
if [[ -n "$PACKAGES_TO_REMOVE" ]] && [[ "$PACKAGES_TO_REMOVE" != " None" ]]; then
    print_info "Removing selected packages..."
    apt-get purge -y $PACKAGES_TO_REMOVE || true
    print_success "Selected packages removed"
else
    print_info "No packages selected for removal"
fi

# Purge snapd completely
print_info "Checking for snapd..."
if dpkg -l | grep -q snapd; then
    print_info "Purging snapd and all snaps..."
    # Remove all snaps
    snap list --all 2>/dev/null | awk '/disabled/{system("snap remove " $1 " --revision=" $3)}' || true
    snap list 2>/dev/null | awk '!/^Name|^core|^snapd/{system("snap remove " $1)}' || true
    
    # Disable and stop services
    systemctl disable snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
    systemctl stop snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
    
    # Purge package
    apt-get purge -y snapd 2>/dev/null || true
    
    # Remove directories
    rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd ~/snap
    print_success "snapd completely removed"
else
    print_info "snapd not installed"
fi

# Cleanup
print_info "Running package cleanup..."
apt-get autoremove --purge -y
apt-get autoclean -y
apt-get clean -y
print_success "Package cleanup complete"

# --- STEP 3: USERS ---
print_header "STEP 3: User Management"

if [[ "$CONFIRM_DELETE" == "yes" ]] && [[ -n "$USERS_TO_DELETE" ]]; then
    while IFS= read -r user; do
        if [[ -n "$user" ]]; then
            print_info "Deleting user and home directory: $user"
            pkill -9 -u "$user" 2>/dev/null || true
            sleep 1
            userdel -r "$user" 2>/dev/null || userdel -f "$user" 2>/dev/null || true
            # Clean up potential leftovers
            rm -rf /home/"$user" 2>/dev/null || true
            print_success "User $user deleted"
        fi
    done <<< "$USERS_TO_DELETE"
else
    print_info "No users deleted"
fi

# --- STEP 4: SWAP ---
print_header "STEP 4: Swap File Configuration"
print_info "Resetting swap to 1GB..."
swapoff -a 2>/dev/null || true
rm -f /swap.img

# Create new 1GB swap file
dd if=/dev/zero of=/swap.img bs=1M count=1024 status=progress 2>&1 | tail -1
chmod 600 /swap.img
mkswap /swap.img >/dev/null

# Update fstab
sed -i '/\/swap.img/d' /etc/fstab
sed -i '/\/swapfile/d' /etc/fstab
echo '/swap.img none swap sw 0 0' >> /etc/fstab
swapon /swap.img
print_success "Swap file created and activated"

# --- STEP 5: DISK CLEANUP ---
print_header "STEP 5: Disk Space Cleanup"

# Clear Update Notifications
rm -rf /var/log/unattended-upgrades/*
rm -rf /var/lib/apt/periodic/*
rm -f /var/lib/update-notifier/updates-available
print_success "Update notifications silenced"

# Clear Apt Lists/Caches
rm -rf /var/lib/apt/lists/*
mkdir -p /var/lib/apt/lists/partial
rm -rf /var/cache/apt/archives/*
print_success "Apt caches cleared"

# Remove old kernels
print_info "Removing old kernels..."
CURRENT_KERNEL=$(uname -r)
dpkg --list | grep -E "linux-image-[0-9]" | awk '{print $2}' | grep -v "$CURRENT_KERNEL" | xargs apt-get purge -y 2>/dev/null || true
dpkg --list | grep -E "linux-headers-[0-9]" | awk '{print $2}' | grep -v "$CURRENT_KERNEL" | xargs apt-get purge -y 2>/dev/null || true
dpkg --list | grep -E "linux-modules-[0-9]" | awk '{print $2}' | grep -v "$CURRENT_KERNEL" | xargs apt-get purge -y 2>/dev/null || true
print_success "Old kernels removed"

# Clear temporary files and caches
rm -rf /tmp/* /var/tmp/*
rm -rf /var/crash/*
rm -rf /var/log/installer/*
rm -rf /home/*/.cache/thumbnails/* 2>/dev/null || true
rm -rf /root/.cache/thumbnails/* 2>/dev/null || true
find / -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
print_success "Temporary files and caches cleared"

# --- STEP 6: GENERALIZATION ---
print_header "STEP 6: OS Generalization"

# Reset machine-id
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Network rules & DHCP
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f /var/lib/dhcp/*.leases
if [[ -d /var/lib/cloud ]]; then
    rm -rf /var/lib/cloud/*
fi
print_success "OS Generalized (machine-id, network rules, DHCP)"

# --- STEP 7: LOGS & HISTORY ---
print_header "STEP 7: Cleaning Logs and History"

# Truncate all logs
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
# Clear login records
truncate -s 0 /var/log/wtmp /var/log/btmp /var/log/lastlog

# Clear Deploy User History
if [[ -d /home/deploy ]]; then
    truncate -s 0 /home/deploy/.bash_history 2>/dev/null || true
    rm -f /home/deploy/.bash_history 2>/dev/null || true
    touch /home/deploy/.bash_history
    chown deploy:deploy /home/deploy/.bash_history
fi

# Clear Root History
truncate -s 0 /root/.bash_history 2>/dev/null || true
history -c 2>/dev/null || true

# Clean Journal
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
print_success "Logs and History Cleared"

# --- STEP 8: FINALIZATION ---
print_header "STEP 8: Finalization"
print_warning "The system will now DELETE this script and REBOOT in 5 seconds..."
print_info "After reboot, the VM is ready for imaging."

echo -n "Rebooting in: 5..."
sleep 1
echo -n " 4..."
sleep 1
echo -n " 3..."
sleep 1
echo -n " 2..."
sleep 1
echo -n " 1..."
sleep 1
echo ""

# Self Destruct
SCRIPT_PATH="$(readlink -f "$0")"
rm -f "$SCRIPT_PATH"

reboot
