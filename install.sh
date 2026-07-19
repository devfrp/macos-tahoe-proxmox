#!/usr/bin/env bash
#
# macOS Tahoe (macOS 26) VM installer for Proxmox VE
# https://github.com/devfrp/macos-tahoe-proxmox
#
# Usage (on the Proxmox host, as root):
#   curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | bash
#
# Configurable via environment variables:
#   curl -fsSL .../install.sh | VMID=990 CORES=8 RAM=16384 DISK=120 bash
#
#   VMID         VM id                  (default: next free id)
#   VM_NAME      VM name                (default: macos-tahoe)
#   CORES        CPU cores              (default: 4)
#   RAM          RAM in MiB             (default: 8192)
#   DISK         main disk size in GiB  (default: 80)
#   STORAGE      disk storage           (default: local-lvm)
#   ISO_STORAGE  ISO storage            (default: local)
#   BRIDGE       network bridge         (default: vmbr0)
#   START        start the VM at the end (default: 1, set 0 to disable)
#   CPU_MODEL    virtual CPU model      (default: Haswell-noTSX-IBRS,
#                works on any Intel/AMD host with AVX2)

set -euo pipefail

# ---------------------------------------------------------------- configuration
VM_NAME="${VM_NAME:-macos-tahoe}"
CORES="${CORES:-4}"
RAM="${RAM:-8192}"
DISK="${DISK:-80}"
STORAGE="${STORAGE:-local-lvm}"
ISO_STORAGE="${ISO_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
START="${START:-1}"

OPENCORE_VERSION="v0.7"
OPENCORE_URL="https://github.com/LongQT-sea/OpenCore-ISO/releases/download/${OPENCORE_VERSION}/LongQT-OpenCore-${OPENCORE_VERSION}.iso"
OPENCORE_ISO="LongQT-OpenCore-${OPENCORE_VERSION}.iso"
MACRECOVERY_URL="https://raw.githubusercontent.com/acidanthera/OpenCorePkg/master/Utilities/macrecovery/macrecovery.py"
TAHOE_BOARD_ID="Mac-CFF7D910A743CAAF"
OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"

ISO_DIR="/var/lib/vz/template/iso"
WORK_DIR="/root/macos-tahoe-installer"

# ---------------------------------------------------------------------- helpers
c_reset='\033[0m'; c_green='\033[1;32m'; c_yellow='\033[1;33m'; c_red='\033[1;31m'; c_blue='\033[1;34m'
info()  { echo -e "${c_blue}[*]${c_reset} $*"; }
ok()    { echo -e "${c_green}[+]${c_reset} $*"; }
warn()  { echo -e "${c_yellow}[!]${c_reset} $*"; }
die()   { echo -e "${c_red}[x]${c_reset} $*" >&2; exit 1; }

main() {

# ----------------------------------------------------------------------- checks
info "Checking environment..."

[[ $EUID -eq 0 ]] || die "This script must be run as root on the Proxmox host."
command -v qm >/dev/null 2>&1 || die "'qm' not found. This script must run on a Proxmox VE host."
command -v pvesh >/dev/null 2>&1 || die "'pvesh' not found. This script must run on a Proxmox VE host."
command -v python3 >/dev/null 2>&1 || die "python3 is required."

grep -qE 'vmx|svm' /proc/cpuinfo || die "CPU virtualization (VT-x/AMD-V) not available."
grep -q avx2 /proc/cpuinfo || die "macOS Tahoe requires a host CPU with AVX2 support."

# Generic virtual CPU, identical on any Intel or AMD host: macOS sees a
# supported Haswell-class Intel CPU with the AVX2 Tahoe requires.
CPU_MODEL="${CPU_MODEL:-Haswell-noTSX-IBRS}"
CPU_ARGS="-cpu ${CPU_MODEL},vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on"
ok "Host CPU OK (AVX2 present) — virtual CPU: ${CPU_MODEL}"

VMID="${VMID:-$(pvesh get /cluster/nextid)}"
if qm status "$VMID" >/dev/null 2>&1; then
    die "VM $VMID already exists. Set another id: curl ... | VMID=xxx bash"
fi
ok "VM id: $VMID"

pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage '$STORAGE' not found (override with STORAGE=...)."
pvesm status --storage "$ISO_STORAGE" >/dev/null 2>&1 || die "ISO storage '$ISO_STORAGE' not found (override with ISO_STORAGE=...)."

# ------------------------------------------------------------- host preparation
info "Configuring KVM (ignore_msrs)..."
echo "options kvm ignore_msrs=1" > /etc/modprobe.d/kvm-macos.conf
if [[ -w /sys/module/kvm/parameters/ignore_msrs ]]; then
    echo 1 > /sys/module/kvm/parameters/ignore_msrs || true
fi
ok "KVM configured"

if ! command -v dmg2img >/dev/null 2>&1; then
    info "Installing dmg2img..."
    apt-get update -qq </dev/null && apt-get install -y -qq dmg2img >/dev/null </dev/null
fi

mkdir -p "$WORK_DIR" "$ISO_DIR"
cd "$WORK_DIR"

# ------------------------------------------------------------------- OpenCore ISO
if [[ -f "$ISO_DIR/$OPENCORE_ISO" ]]; then
    ok "OpenCore ISO already present"
else
    info "Downloading OpenCore ISO (${OPENCORE_VERSION})..."
    curl -fSL --progress-bar -o "$ISO_DIR/$OPENCORE_ISO.tmp" "$OPENCORE_URL"
    mv "$ISO_DIR/$OPENCORE_ISO.tmp" "$ISO_DIR/$OPENCORE_ISO"
    ok "OpenCore ISO downloaded"
fi

# ------------------------------------------------------------- Tahoe recovery image
RECOVERY_IMG="$WORK_DIR/tahoe-recovery.img"
if [[ -f "$RECOVERY_IMG" ]]; then
    ok "Recovery image already present"
else
    info "Downloading macOS Tahoe recovery from Apple servers..."
    curl -fsSL -o macrecovery.py "$MACRECOVERY_URL"
    python3 macrecovery.py -b "$TAHOE_BOARD_ID" -m 00000000000000000 -os latest download
    DMG="$(find "$WORK_DIR" -name 'BaseSystem.dmg' | head -n1)"
    [[ -n "$DMG" ]] || die "BaseSystem.dmg not found after download."
    info "Converting recovery image (dmg2img)..."
    dmg2img -i "$DMG" "$RECOVERY_IMG" >/dev/null
    ok "Recovery image ready"
fi

# ------------------------------------------------------------------- VM creation
info "Creating VM $VMID ($VM_NAME)..."
qm create "$VMID" \
    --name "$VM_NAME" \
    --ostype other \
    --machine q35 \
    --bios ovmf \
    --cores "$CORES" \
    --sockets 1 \
    --cpu Haswell \
    --memory "$RAM" \
    --balloon 0 \
    --vga vmware \
    --net0 "virtio,bridge=$BRIDGE" \
    --agent enabled=1 \
    --tablet 1

qm set "$VMID" --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0"
qm set "$VMID" --virtio0 "$STORAGE:$DISK,cache=unsafe,discard=on"
qm set "$VMID" --ide2 "$ISO_STORAGE:iso/$OPENCORE_ISO,media=cdrom,cache=unsafe"
qm set "$VMID" --sata0 "$STORAGE:0,import-from=$RECOVERY_IMG"
qm set "$VMID" --boot order=ide2
qm set "$VMID" --args "-device isa-applesmc,osk=\"$OSK\" -smbios type=2 -device usb-kbd,bus=ehci.0,port=2 -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off $CPU_ARGS"

ok "VM $VMID created"

if [[ "$START" == "1" ]]; then
    info "Starting VM $VMID..."
    qm start "$VMID"
    ok "VM started"
fi

# ----------------------------------------------------------------------- summary
echo
echo -e "${c_green}=========================================================${c_reset}"
echo -e "${c_green}  macOS Tahoe VM ready to install${c_reset}"
echo -e "${c_green}=========================================================${c_reset}"
echo
echo "  VM id      : $VMID"
echo "  Name       : $VM_NAME"
echo "  CPU        : $CORES cores (virtual: $CPU_MODEL)"
echo "  RAM        : $RAM MiB"
echo "  Disk       : ${DISK}G on $STORAGE"
echo
echo "  Next steps:"
if [[ "$START" == "1" ]]; then
    echo "  1. The VM is already running"
else
    echo "  1. Start the VM:            qm start $VMID"
fi
echo "  2. Open the console in the Proxmox web UI"
echo "  3. In OpenCore, boot 'macOS Base System'"
echo "  4. Disk Utility -> erase the ${DISK}G VirtIO disk (APFS, GUID)"
echo "  5. Install macOS Tahoe (downloads from Apple, ~30-60 min)"
echo "  6. After install, detach the recovery disk:"
echo "       qm set $VMID --delete sata0"
echo
echo "  Keep the OpenCore ISO attached: the VM boots through it."
echo "  Remove everything:            qm destroy $VMID"
echo

}

main "$@"
