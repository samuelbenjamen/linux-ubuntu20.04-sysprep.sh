#!/bin/bash
#
# Ubuntu Sysprep Script - OS Generalization for Golden Image
# Compatible with Ubuntu 18.04, 20.04, 22.04, 24.04 and newer
# Must be run as root
#
# Purpose: Prepares a cloned Ubuntu VM for reuse by:
# - Setting new hostname
# - Managing packages interactively
# - Removing all users except root and deploy
# - Resetting swap to 1GB
# - Generalizing OS (machine-id, logs, history)
# - Rebooting for immediate reuse
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
UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "Unknown")
print_info "Detected Ubuntu version: $UBUNTU_VERSION ($UBUNTU_CODENAME)"
print_info "This script will prepare your cloned VM for reuse"
echo ""

# ============================================================================
# COLLECT ALL USER INPUT UPFRONT
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
    # Fallback method for systems without initial-status.gz
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
print_warning "This script will DELETE all users and their home directories"
print_warning "EXCEPT: root and deploy"
echo ""

# Get list of all users with UID >= 1000 (regular users)
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
    print_info "Preserved users: root, deploy"
    echo ""
    
    read -p "Continue with user deletion? Type 'yes' to confirm: " CONFIRM_DELETE
fi

echo ""

# ---------- FINAL CONFIRMATION ----------
print_header "CONFIGURATION SUMMARY"
echo ""
print_info "Configuration Summary:"
echo "  → New hostname: $NEW_HOSTNAME"
if [[ -n "$PKG_NUMS" ]]; then
    PACKAGES_TO_REMOVE=""
    for num in $PKG_NUMS; do
        if [[ -n "${PKG_MAP[$num]}" ]]; then
            PACKAGES_TO_REMOVE="$PACKAGES_TO_REMOVE ${PKG_MAP[$num]}"
        fi
    done
    if [[ -n "$PACKAGES_TO_REMOVE" ]]; then
        echo "  → Packages to remove:$PACKAGES_TO_REMOVE"
    else
        echo "  → Packages to remove: None (invalid selection)"
    fi
else
    echo "  → Packages to remove: None"
fi

if [[ "$CONFIRM_DELETE" == "yes" ]] && [[ -n "$USERS_TO_DELETE" ]]; then
    echo "  → Users to delete: $(echo $USERS_TO_DELETE | tr '\n' ' ')"
else
    echo "  → Users to delete: None"
fi

echo "  → Swap file: Will be reset to 1GB"
echo "  → Disk cleanup: Will remove old kernels, docs, caches, and temporary files"
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
# EXECUTION PHASE - NO MORE QUESTIONS
# ============================================================================

# ============================================================================
# STEP 1: HOSTNAME CONFIGURATION
# ============================================================================
print_header "STEP 1: Hostname Configuration"
echo ""

print_info "Setting hostname to: $NEW_HOSTNAME"
hostnamectl set-hostname "$NEW_HOSTNAME"

# Update /etc/hosts
if grep -q "^127.0.1.1" /etc/hosts; then
    sed -i "s/^127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
else
    echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
fi

print_success "Hostname configured successfully"
echo ""

# ============================================================================
# STEP 2: PACKAGE MANAGEMENT
# ============================================================================
print_header "STEP 2: Package Management"
echo ""

# Remove selected packages
if [[ -n "$PACKAGES_TO_REMOVE" ]]; then
    print_info "Removing selected packages:$PACKAGES_TO_REMOVE"
    apt-get purge -y $PACKAGES_TO_REMOVE || true
    print_success "Selected packages removed"
else
    print_info "No packages selected for removal"
fi

echo ""

# Purge snapd completely
print_info "Checking for snapd..."
if dpkg -l | grep -q snapd; then
    print_info "Purging snapd and all snaps..."
    # Remove all snaps
    snap list --all 2>/dev/null | awk '/disabled/{system("snap remove " $1 " --revision=" $3)}' || true
    snap list 2>/dev/null | awk '!/^Name|^core|^snapd/{system("snap remove " $1)}' || true
    
    # Disable snapd services
    systemctl disable snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
    systemctl stop snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
    
    # Purge snapd package
    apt-get purge -y snapd 2>/dev/null || true
    
    # Remove all snap directories
    rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd ~/snap
    
    print_success "snapd completely removed"
else
    print_info "snapd not installed"
fi

# Cleanup packages
print_info "Running package cleanup (autoremove, autoclean, clean)..."
apt-get autoremove --purge -y
apt-get autoclean -y
apt-get clean -y
print_success "Package cleanup complete"
echo ""

# ============================================================================
# STEP 3: USER MANAGEMENT
# ============================================================================
print_header "STEP 3: User Management"
echo ""

if [[ "$CONFIRM_DELETE" == "yes" ]] && [[ -n "$USERS_TO_DELETE" ]]; then
    print_info "Deleting users and their home directories..."
    
    while IFS= read -r user; do
        if [[ -n "$user" ]]; then
            print_info "Deleting user and home directory: $user"
            
            # Kill any processes owned by the user
            pkill -9 -u "$user" 2>/dev/null || true
            sleep 1
            
            # Delete user and their home directory
            userdel -r "$user" 2>/dev/null || userdel -f "$user" 2>/dev/null || true
            
            # Remove user's mail spool if exists
            rm -rf /var/mail/"$user" /var/spool/mail/"$user" 2>/dev/null || true
            
            # Remove any remaining home directory fragments
            rm -rf /home/"$user" 2>/dev/null || true
            
            print_success "User $user deleted"
        fi
    done <<< "$USERS_TO_DELETE"
    
    print_success "User cleanup complete"
else
    print_info "No users to delete or deletion cancelled"
fi

echo ""

# ============================================================================
# STEP 4: SWAP FILE CONFIGURATION
# ============================================================================
print_header "STEP 4: Swap File Configuration"
echo ""

print_info "Configuring swap file to exactly 1GB..."

# Disable current swap
swapoff -a 2>/dev/null || true

# Remove old swap file if exists
if [[ -f /swap.img ]]; then
    rm -f /swap.img
    print_info "Removed existing swap file"
fi

# Create new 1GB swap file
print_info "Creating 1GB swap file at /swap.img (this may take a moment)..."
dd if=/dev/zero of=/swap.img bs=1M count=1024 status=progress 2>&1 | tail -1
chmod 600 /swap.img
mkswap /swap.img >/dev/null

# Update fstab - remove old swap entries and add new one
sed -i '/\/swap.img/d' /etc/fstab
sed -i '/\/swapfile/d' /etc/fstab
echo '/swap.img none swap sw 0 0' >> /etc/fstab

# Enable swap
swapon /swap.img

# Verify swap
SWAP_SIZE=$(free -h | awk '/Swap:/ {print $2}')
print_success "Swap file created and activated: $SWAP_SIZE"
echo ""

# ============================================================================
# STEP 5: AGGRESSIVE DISK SPACE CLEANUP
# ============================================================================
print_header "STEP 5: Aggressive Disk Space Cleanup"
echo ""

print_info "Analyzing disk usage before cleanup..."
DISK_BEFORE=$(df -h / | awk 'NR==2 {print $3}')
echo "  Current usage: $DISK_BEFORE"
echo ""

# Clear unattended-upgrades logs
if [[ -d /var/log/unattended-upgrades ]]; then
    rm -rf /var/log/unattended-upgrades/*
    print_success "Cleared unattended-upgrades logs"
fi

# Clear apt periodic data
if [[ -d /var/lib/apt/periodic ]]; then
    rm -rf /var/lib/apt/periodic/*
    print_success "Cleared apt periodic data"
fi

# Clear update-notifier stamps
if [[ -d /var/lib/update-notifier ]]; then
    rm -f /var/lib/update-notifier/updates-available
    rm -f /var/lib/update-notifier/user.d/*
    print_success "Cleared update-notifier stamps"
fi

# Remove apt lists to prevent stale update information
rm -rf /var/lib/apt/lists/*
mkdir -p /var/lib/apt/lists/partial
print_success "Cleared apt lists"

# Clear apt cache completely
print_info "Clearing apt cache..."
apt-get clean
rm -rf /var/cache/apt/archives/*
rm -rf /var/cache/apt/*.bin
print_success "Apt cache cleared"

# Remove old kernels (keep only current running kernel)
print_info "Removing old kernels..."
CURRENT_KERNEL=$(uname -r)
dpkg --list | grep -E "linux-image-[0-9]" | awk '{print $2}' | grep -v "$CURRENT_KERNEL" | xargs apt-get purge -y 2>/dev/null || true
dpkg --list | grep -E "linux-headers-[0-9]" | awk '{print $2}' | grep -v "$CURRENT_KERNEL" | xargs apt-get purge -y 2>/dev/null || true
dpkg --list | grep -E "linux-modules-[0-9]" | awk '{print $2}' | grep -v "$CURRENT_KERNEL" | xargs apt-get purge -y 2>/dev/null || true
print_success "Old kernels removed"

# Clean up orphaned packages again after kernel removal
apt-get autoremove --purge -y
apt-get autoclean -y

# Remove documentation and man pages (optional but saves space)
print_info "Removing unnecessary documentation..."
rm -rf /usr/share/doc/*
rm -rf /usr/share/man/*
rm -rf /usr/share/info/*
rm -rf /usr/share/lintian/*
rm -rf /usr/share/linda/*
print_success "Documentation removed"

# Clear thumbnail cache
print_info "Clearing thumbnail caches..."
rm -rf /home/*/.cache/thumbnails/* 2>/dev/null || true
rm -rf /root/.cache/thumbnails/* 2>/dev/null || true
print_success "Thumbnail caches cleared"

# Remove temporary files
print_info "Removing temporary files..."
rm -rf /tmp/*
rm -rf /var/tmp/*
print_success "Temporary files removed"

# Clear installer logs and crash reports
print_info "Clearing installer logs and crash reports..."
rm -rf /var/log/installer/*
rm -rf /var/crash/*
rm -rf /var/log/dist-upgrade/*
print_success "Installer logs and crash reports cleared"

# Remove landscape (if not needed)
if dpkg -l | grep -q landscape-common; then
    print_info "Removing landscape-common (not needed for most setups)..."
    apt-get purge -y landscape-common landscape-client 2>/dev/null || true
    print_success "Landscape removed"
fi

# Clear Python cache
print_info "Clearing Python cache files..."
find / -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
find / -name "*.pyc" -delete 2>/dev/null || true
print_success "Python cache cleared"

# Remove any .gz rotated logs
print_info "Removing rotated log files..."
find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log -type f -name "*.1" -delete 2>/dev/null || true
find /var/log -type f -name "*.old" -delete 2>/dev/null || true
print_success "Rotated logs removed"

# Zero out free space to help with compression (optional, takes time)
# Uncomment if you want maximum compression when exporting VM
# print_info "Zeroing out free space (this may take several minutes)..."
# dd if=/dev/zero of=/EMPTY bs=1M 2>/dev/null || true
# rm -f /EMPTY
# print_success "Free space zeroed"

print_info "Analyzing disk usage after cleanup..."
DISK_AFTER=$(df -h / | awk 'NR==2 {print $3}')
echo "  Usage after cleanup: $DISK_AFTER (was: $DISK_BEFORE)"
echo ""

print_success "Aggressive disk cleanup complete"
echo ""

# ============================================================================
# STEP 6: OS GENERALIZATION
# ============================================================================
print_header "STEP 6: OS Generalization"
echo ""

# Reset machine-id
print_info "Resetting machine-id..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id
print_success "machine-id reset (will be regenerated on boot)"

# Remove persistent net rules (for older Ubuntu versions)
print_info "Removing persistent net rules..."
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f /etc/udev/rules.d/75-persistent-net-generator.rules
rm -f /lib/udev/rules.d/75-persistent-net-generator.rules
print_success "Persistent net rules removed"

# Clear netplan configuration cache (for Ubuntu 18.04+)
if [[ -d /etc/netplan ]]; then
    print_info "Clearing netplan cache..."
    rm -f /etc/netplan/*.yaml.bak 2>/dev/null || true
    print_success "Netplan cache cleared"
fi

# SSH host keys are preserved (not removed)
print_info "SSH host keys preserved (not removed)"

# Clear cloud-init data if present
if [[ -d /var/lib/cloud ]]; then
    print_info "Cleaning cloud-init data..."
    cloud-init clean --logs --seed 2>/dev/null || rm -rf /var/lib/cloud/* 2>/dev/null || true
    print_success "cloud-init data cleaned"
fi

# Remove DHCP leases
print_info "Removing DHCP leases..."
rm -f /var/lib/dhcp/*.leases
rm -f /var/lib/dhclient/*.leases
print_success "DHCP leases removed"

echo ""

# ============================================================================
# STEP 7: LOG AND HISTORY CLEANUP
# ============================================================================
print_header "STEP 7: Cleaning Logs and History"
echo ""

# Truncate all log files
print_info "Truncating all log files..."
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
print_success "All log files truncated"

# Clear login history
print_info "Clearing login history..."
truncate -s 0 /var/log/wtmp 2>/dev/null || true
truncate -s 0 /var/log/btmp 2>/dev/null || true
truncate -s 0 /var/log/lastlog 2>/dev/null || true
print_success "Login history cleared (wtmp, btmp, lastlog)"

# Clear bash history for deploy user only
print_info "Clearing bash history for deploy user..."
if [[ -d /home/deploy ]]; then
    truncate -s 0 /home/deploy/.bash_history 2>/dev/null || true
    rm -f /home/deploy/.bash_history 2>/dev/null || true
    touch /home/deploy/.bash_history
    chown deploy:deploy /home/deploy/.bash_history 2>/dev/null || true
    print_success "Deploy user bash history cleared"
else
    print_warning "Deploy user home directory not found"
fi

# Clear root bash history
if [[ -f /root/.bash_history ]]; then
    truncate -s 0 /root/.bash_history
    print_success "Root bash history cleared"
fi

# Clear system-wide command history
history -c 2>/dev/null || true

# Clear journal logs
print_info "Clearing systemd journal logs..."
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true
print_success "Journal logs cleared"

echo ""

# ============================================================================
# STEP 8: FINALIZATION
# ============================================================================
print_header "STEP 8: Finalization"
echo ""

# Clear current session history
export HISTFILE=/dev/null
unset HISTFILE
export HISTSIZE=0

print_success "Sysprep process completed successfully!"
echo ""
print_info "Summary of changes:"
echo "  ✓ Hostname set to: $NEW_HOSTNAME"
echo "  ✓ Packages managed and snapd removed"
echo "  ✓ Users cleaned (preserved: root, deploy)"
echo "  ✓ Swap file set to 1GB"
echo "  ✓ Aggressive disk cleanup performed"
echo "  ✓ Update warnings silenced"
echo "  ✓ OS generalized (machine-id, DHCP, logs)"
echo "  ✓ All logs and history cleared"
echo ""
print_warning "The system will now DELETE this script and RESTART in 5 seconds..."
print_info "After restart, the VM will be ready for immediate reuse."
echo ""
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

# Delete this script
SCRIPT_PATH="$(readlink -f "$0")"
rm -f "$SCRIPT_PATH"

# Restart the system
reboot
