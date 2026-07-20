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
#   VERSION      macOS version: tahoe (default), sequoia, sonoma, ventura
#   INTERACTIVE  set 0 to disable the terminal questions
#   CPU_MODEL    virtual CPU model      (default: auto — best model the host
#                supports; on non-AVX2 hosts CryptexFixup is injected into
#                OpenCore automatically so macOS Tahoe still installs)

set -Eeuo pipefail
trap 'echo -e "\033[1;31m[x]\033[0m Command failed (line $LINENO): $BASH_COMMAND" >&2' ERR

# ---------------------------------------------------------------- configuration
VM_NAME="${VM_NAME:-}"
CORES="${CORES:-4}"
RAM="${RAM:-}"
DISK="${DISK:-}"
STORAGE="${STORAGE:-}"
ISO_STORAGE="${ISO_STORAGE:-local}"
BRIDGE="${BRIDGE:-vmbr0}"
START="${START:-1}"
MACOS_VERSION="${VERSION:-}"

OPENCORE_VERSION="v0.7"
OPENCORE_URL="https://github.com/LongQT-sea/OpenCore-ISO/releases/download/${OPENCORE_VERSION}/LongQT-OpenCore-${OPENCORE_VERSION}.iso"
OPENCORE_ISO="LongQT-OpenCore-${OPENCORE_VERSION}.iso"
MACRECOVERY_URL="https://raw.githubusercontent.com/acidanthera/OpenCorePkg/master/Utilities/macrecovery/macrecovery.py"
OSK="ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"

WORK_DIR="/root/macos-tahoe-installer"

# ---------------------------------------------------------------------- helpers
c_reset='\033[0m'; c_green='\033[1;32m'; c_yellow='\033[1;33m'; c_red='\033[1;31m'; c_blue='\033[1;34m'
info()  { echo -e "${c_blue}[*]${c_reset} $*"; }
ok()    { echo -e "${c_green}[+]${c_reset} $*"; }
warn()  { echo -e "${c_yellow}[!]${c_reset} $*"; }
die()   { echo -e "${c_red}[x]${c_reset} $*" >&2; exit 1; }

# --------------------------------------------------------------------- finalize
# After macOS is installed: copy OpenCore to the VM's own EFI partition,
# detach the installer media and boot straight from disk.
#   curl -fsSL .../install.sh | bash -s -- finalize <VMID>
finalize_vm() {
    local vmid="$1"
    [[ -n "$vmid" ]] || die "Usage: ... | bash -s -- finalize <VMID>"
    [[ $EUID -eq 0 ]] || die "This script must be run as root on the Proxmox host."
    command -v qm >/dev/null 2>&1 || die "'qm' not found. This must run on a Proxmox VE host."
    qm status "$vmid" >/dev/null 2>&1 || die "VM $vmid not found."

    local iso_vol iso_file oc_vol disk_vol disk_dev
    iso_vol="$(qm config "$vmid" | sed -n 's/^ide2: \([^,]*\).*/\1/p')"
    oc_vol="$(qm config "$vmid" | sed -n 's/^sata1: \([^,]*\).*/\1/p')"
    [[ -n "$iso_vol" || -n "$oc_vol" ]] || die "No OpenCore media (ide2/sata1) on VM $vmid — nothing to finalize."
    [[ -z "$iso_vol" ]] || iso_file="$(pvesm path "$iso_vol")"
    disk_vol="$(qm config "$vmid" | sed -n 's/^virtio0: \([^,]*\).*/\1/p')"
    [[ -n "$disk_vol" ]] || die "No virtio0 disk on VM $vmid."
    disk_dev="$(pvesm path "$disk_vol")"
    [[ -e "$disk_dev" ]] || die "Disk of VM $vmid has no local path — finalize manually (see README)."

    local pkgs=()
    command -v kpartx  >/dev/null 2>&1 || pkgs+=(kpartx)
    command -v mcopy   >/dev/null 2>&1 || pkgs+=(mtools)
    command -v xorriso >/dev/null 2>&1 || pkgs+=(xorriso)
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        info "Installing ${pkgs[*]}..."
        apt-get update -qq </dev/null && apt-get install -y -qq "${pkgs[@]}" >/dev/null </dev/null
    fi

    if qm status "$vmid" | grep -q running; then
        info "Shutting down VM $vmid..."
        qm shutdown "$vmid" --timeout 120 || qm stop "$vmid"
    fi

    local tmp; tmp="$(mktemp -d)"
    if [[ -n "$iso_vol" ]]; then
        xorriso -osirrox on -indev "$iso_file" -extract /BOOT.img "$tmp/BOOT.img" >/dev/null 2>&1 || true
        [[ -f "$tmp/BOOT.img" ]] || die "Failed to extract BOOT.img from $iso_file."
        chmod +w "$tmp/BOOT.img"
        mcopy -si "$tmp/BOOT.img" ::/EFI "$tmp/" >/dev/null 2>&1
    else
        # OpenCore lives on a small FAT boot disk (non-AVX2 setups)
        local oc_dev; oc_dev="$(pvesm path "$oc_vol")"
        [[ -e "$oc_dev" ]] || die "OpenCore boot disk has no local path."
        mkdir -p "$tmp/ocsrc"
        mount -t vfat -o ro "$oc_dev" "$tmp/ocsrc" || die "Cannot mount the OpenCore boot disk."
        cp -r "$tmp/ocsrc/EFI" "$tmp/EFI"
        umount "$tmp/ocsrc"
    fi
    [[ -d "$tmp/EFI" ]] || die "Failed to read the OpenCore EFI folder."

    info "Copying OpenCore to the EFI partition of VM $vmid..."
    local mapname esp
    mapname="$(kpartx -av "$disk_dev" | awk 'NR==1 {print $3}')"
    [[ -n "$mapname" ]] || die "No partitions found on the VM disk — install macOS first."
    esp="/dev/mapper/$mapname"
    mkdir -p "$tmp/esp"
    if ! mount -t vfat "$esp" "$tmp/esp" 2>/dev/null; then
        kpartx -d "$disk_dev" >/dev/null 2>&1 || true
        die "EFI partition not mountable — erase the disk in Disk Utility and install macOS first."
    fi
    cp -r "$tmp/EFI" "$tmp/esp/"
    sync
    umount "$tmp/esp"
    kpartx -d "$disk_dev" >/dev/null 2>&1 || true
    rm -rf "$tmp"

    qm set "$vmid" --delete ide2 2>/dev/null || true
    qm set "$vmid" --delete sata0 2>/dev/null || true
    qm set "$vmid" --delete sata1 2>/dev/null || true
    qm set "$vmid" --boot order=virtio0
    qm start "$vmid"
    ok "VM $vmid is now standalone: it boots OpenCore from its own disk."
    exit 0
}

main() {

if [[ "${1:-}" == "finalize" ]]; then
    finalize_vm "${2:-}"
fi

# ----------------------------------------------------------------------- checks
info "Checking environment..."

[[ $EUID -eq 0 ]] || die "This script must be run as root on the Proxmox host."
command -v qm >/dev/null 2>&1 || die "'qm' not found. This script must run on a Proxmox VE host."
command -v pvesh >/dev/null 2>&1 || die "'pvesh' not found. This script must run on a Proxmox VE host."
command -v python3 >/dev/null 2>&1 || die "python3 is required."

grep -qE 'vmx|svm' /proc/cpuinfo || die "CPU virtualization (VT-x/AMD-V) not available."

# Universal virtual CPU: pick the best model the host can actually provide.
# macOS Tahoe wants AVX2; on hosts without it, CryptexFixup is injected into
# the OpenCore ISO so macOS installs its non-AVX2 (Rosetta) system files.
CPU_FLAGS="$(grep -m1 '^flags' /proc/cpuinfo)"
NEED_CRYPTEX=0
if [[ -n "${CPU_MODEL:-}" ]]; then
    grep -qw avx2 <<<"$CPU_FLAGS" || NEED_CRYPTEX=1
elif grep -qw avx2 <<<"$CPU_FLAGS"; then
    CPU_MODEL="Haswell-noTSX-IBRS"
elif grep -qw avx <<<"$CPU_FLAGS"; then
    CPU_MODEL="SandyBridge-IBRS"; NEED_CRYPTEX=1
elif grep -qw sse4_2 <<<"$CPU_FLAGS"; then
    CPU_MODEL="Nehalem-IBRS"; NEED_CRYPTEX=1
else
    die "Host CPU too old: macOS needs at least SSE4.2."
fi
CPU_ARGS="-cpu ${CPU_MODEL},vendor=GenuineIntel,+invtsc,+hypervisor,kvm=on,vmware-cpuid-freq=on"
if [[ $NEED_CRYPTEX -eq 1 ]]; then
    warn "Host CPU has no AVX2 — CryptexFixup will be added to OpenCore"
    warn "(macOS updates will require full installers instead of small deltas)"
fi
ok "Virtual CPU: ${CPU_MODEL}"

# -------------------------------------------------------------- interactive setup
# With a terminal available, ask for the main settings; environment variables
# (VERSION=... STORAGE=... RAM=... DISK=...) skip the questions, and without
# a terminal the defaults apply — automation stays fully non-interactive.
ask() {
    local a
    printf '%s [%s]: ' "$1" "$2" > /dev/tty
    IFS= read -r a < /dev/tty || a=""
    echo "${a:-$2}"
}
if [[ "${INTERACTIVE:-1}" == "1" ]] && { : </dev/tty; } 2>/dev/null && { : >/dev/tty; } 2>/dev/null; then
    if [[ -z "$MACOS_VERSION" ]]; then
        printf '\n  1) Tahoe (26)  2) Sequoia (15)  3) Sonoma (14)  4) Ventura (13)\n' > /dev/tty
        case "$(ask "macOS version" 1)" in
            2*|*[sS]equoia*) MACOS_VERSION=sequoia ;;
            3*|*[sS]onoma*)  MACOS_VERSION=sonoma ;;
            4*|*[vV]entura*) MACOS_VERSION=ventura ;;
            *)               MACOS_VERSION=tahoe ;;
        esac
    fi
    if [[ -z "$STORAGE" ]]; then
        printf '\n  Available storages for the VM disks:\n' > /dev/tty
        pvesm status --content images 2>/dev/null \
            | awk 'NR>1 {printf "    %-16s %6.1f GiB free\n", $1, $6/1024/1024}' > /dev/tty
        STORAGE="$(ask "Storage" local-lvm)"
    fi
    [[ -n "$RAM"  ]] || RAM="$(ask "RAM in MiB" 8192)"
    [[ -n "$DISK" ]] || DISK="$(ask "Disk size in GiB" 80)"
fi
MACOS_VERSION="${MACOS_VERSION:-tahoe}"
STORAGE="${STORAGE:-local-lvm}"
RAM="${RAM:-8192}"
DISK="${DISK:-80}"

case "$MACOS_VERSION" in
    tahoe)   MACOS_NAME="Tahoe";   BOARD_ID="Mac-CFF7D910A743CAAF"; OS_ARG="latest";  SMBIOS_PRODUCT="iMac20,1" ;;
    sequoia) MACOS_NAME="Sequoia"; BOARD_ID="Mac-7BA5B2D9E42DDD94"; OS_ARG="default"; SMBIOS_PRODUCT="iMacPro1,1" ;;
    sonoma)  MACOS_NAME="Sonoma";  BOARD_ID="Mac-827FAC58A8FDFA22"; OS_ARG="default"; SMBIOS_PRODUCT="MacBookAir8,1" ;;
    ventura) MACOS_NAME="Ventura"; BOARD_ID="Mac-B4831CEBD52A0C4C"; OS_ARG="default"; SMBIOS_PRODUCT="MacBookPro14,1" ;;
    *) die "Unknown VERSION '$MACOS_VERSION' (tahoe|sequoia|sonoma|ventura)" ;;
esac
VM_NAME="${VM_NAME:-macos-$MACOS_VERSION}"
ok "Target: macOS $MACOS_NAME, storage $STORAGE, ${RAM} MiB RAM, ${DISK}G disk"

VMID="${VMID:-$(pvesh get /cluster/nextid)}"
if qm status "$VMID" >/dev/null 2>&1; then
    die "VM $VMID already exists. Set another id: curl ... | VMID=xxx bash"
fi
ok "VM id: $VMID"

pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage '$STORAGE' not found (override with STORAGE=...)."
pvesm status --storage "$ISO_STORAGE" >/dev/null 2>&1 || die "ISO storage '$ISO_STORAGE' not found (override with ISO_STORAGE=...)."

# Resolve the ISO directory from the actual ISO storage configuration
ISO_DIR="$(dirname "$(pvesm path "$ISO_STORAGE:iso/probe.iso" 2>/dev/null)" 2>/dev/null || true)"
[[ -n "$ISO_DIR" && "$ISO_DIR" != "." ]] || ISO_DIR="/var/lib/vz/template/iso"

# A macOS Tahoe install writes roughly 35 GB of real data
STORAGE_AVAIL_KB="$(pvesm status --storage "$STORAGE" 2>/dev/null | awk 'NR==2 {print $6}')"
if [[ "$STORAGE_AVAIL_KB" =~ ^[0-9]+$ ]] && (( STORAGE_AVAIL_KB < 40 * 1024 * 1024 )); then
    warn "Storage '$STORAGE' has only $((STORAGE_AVAIL_KB / 1024 / 1024)) GiB available."
    warn "A macOS install needs ~35-40 GiB of real space: it may fail."
    warn "Free some space or use another storage (STORAGE=...)."
fi

# ------------------------------------------------------------- host preparation
info "Configuring KVM (ignore_msrs)..."
echo "options kvm ignore_msrs=1" > /etc/modprobe.d/kvm-macos.conf
if [[ -w /sys/module/kvm/parameters/ignore_msrs ]]; then
    echo 1 > /sys/module/kvm/parameters/ignore_msrs || true
fi
ok "KVM configured"

CLOCKSOURCE="$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource 2>/dev/null || echo unknown)"
if [[ "$CLOCKSOURCE" != "tsc" ]]; then
    warn "Host clocksource is '$CLOCKSOURCE' (not TSC): macOS may freeze with several cores."
    warn "Fix: add 'tsc=reliable' to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub,"
    warn "then run 'update-grub' and reboot the host."
fi

PKGS=()
command -v dmg2img >/dev/null 2>&1 || PKGS+=(dmg2img)
command -v xorriso  >/dev/null 2>&1 || PKGS+=(xorriso)
command -v mcopy    >/dev/null 2>&1 || PKGS+=(mtools)
if [[ ${#PKGS[@]} -gt 0 ]]; then
    info "Installing ${PKGS[*]}..."
    apt-get update -qq </dev/null && apt-get install -y -qq "${PKGS[@]}" >/dev/null </dev/null
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

# The stock ISO ships placeholder PlatformInfo (SystemProductName iMac19,1,
# all-zero serial/MLB/UUID) which macOS's installer/Software Update rejects
# ("An error occurred preparing the software update"). A real SMBIOS is
# generated per macOS version and patched into OpenCore's config.plist.
# On non-AVX2 hosts CryptexFixup is injected too. Rebuilt ISOs are not
# reliably bootable across xorriso versions, so the patched FAT boot image is
# instead attached as a small UEFI boot disk (OVMF boots it natively).
OC_BOOT_IMG="$WORK_DIR/opencore-boot-${MACOS_VERSION}.img"
if [[ -f "$OC_BOOT_IMG" ]]; then
    ok "OpenCore boot image already present"
else
    info "Building the OpenCore boot image (SMBIOS: $SMBIOS_PRODUCT)..."
    CTMP="$WORK_DIR/oc-build"
    rm -rf "$CTMP" && mkdir -p "$CTMP"

    if [[ $NEED_CRYPTEX -eq 1 ]]; then
        CRYPTEX_ZIP_URL="$(curl -fsSL https://api.github.com/repos/acidanthera/CryptexFixup/releases/latest 2>/dev/null \
            | python3 -c "import json,sys; print([a['browser_download_url'] for a in json.load(sys.stdin)['assets'] if 'RELEASE' in a['name']][0])" 2>/dev/null || true)"
        # Fallback to a pinned release if the GitHub API is rate-limited
        [[ -n "$CRYPTEX_ZIP_URL" ]] || CRYPTEX_ZIP_URL="https://github.com/acidanthera/CryptexFixup/releases/download/1.0.5/CryptexFixup-1.0.5-RELEASE.zip"
        curl -fsSL -o "$CTMP/cryptex.zip" "$CRYPTEX_ZIP_URL"
        python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
            "$CTMP/cryptex.zip" "$CTMP"
        [[ -d "$CTMP/CryptexFixup.kext" ]] || die "CryptexFixup.kext not found in release archive."
    fi

    # xorriso may exit non-zero on mere warnings: check the output instead
    xorriso -osirrox on -indev "$ISO_DIR/$OPENCORE_ISO" \
        -extract /BOOT.img "$CTMP/BOOT.img" >/dev/null 2>&1 || true
    [[ -f "$CTMP/BOOT.img" ]] || die "Failed to extract BOOT.img from the OpenCore ISO."
    chmod +w "$CTMP/BOOT.img"

    mcopy -i "$CTMP/BOOT.img" ::/EFI/OC/config.plist "$CTMP/config.plist"
    python3 - "$CTMP/config.plist" "$SMBIOS_PRODUCT" "$NEED_CRYPTEX" <<'PYEOF'
import plistlib, sys, uuid, secrets

path, product, need_cryptex = sys.argv[1], sys.argv[2], sys.argv[3] == '1'
with open(path, 'rb') as f:
    cfg = plistlib.load(f)

charset = "0123456789ABCDEFGHJKLMNPQRSTUVWXYZ"  # Apple-style, no ambiguous I/O
def rnd(n):
    return ''.join(secrets.choice(charset) for _ in range(n))

generic = cfg['PlatformInfo']['Generic']
generic['SystemProductName'] = product
generic['SystemSerialNumber'] = rnd(12)
generic['MLB'] = rnd(17)
generic['SystemUUID'] = str(uuid.uuid4()).upper()
generic['ROM'] = secrets.token_bytes(6)

if need_cryptex:
    kexts = cfg['Kernel']['Add']
    if not any(k.get('BundlePath') == 'CryptexFixup.kext' for k in kexts):
        kexts.append({
            'Arch': 'x86_64',
            'BundlePath': 'CryptexFixup.kext',
            'Comment': 'Rosetta cryptex on non-AVX2 CPUs',
            'Enabled': True,
            'ExecutablePath': 'Contents/MacOS/CryptexFixup',
            'MaxKernel': '',
            'MinKernel': '22.0.0',
            'PlistPath': 'Contents/Info.plist',
        })

with open(path, 'wb') as f:
    plistlib.dump(cfg, f)
PYEOF

    if [[ $NEED_CRYPTEX -eq 1 ]]; then
        (
            cd "$CTMP/CryptexFixup.kext"
            mmd -i "$CTMP/BOOT.img" "::/EFI/OC/Kexts/CryptexFixup.kext" 2>/dev/null || true
            find . -type d | sed 's|^\./||;/^\.$/d' | sort | while read -r d; do
                mmd -i "$CTMP/BOOT.img" "::/EFI/OC/Kexts/CryptexFixup.kext/$d" 2>/dev/null || true
            done
            find . -type f | sed 's|^\./||' | while read -r f; do
                mcopy -i "$CTMP/BOOT.img" "$f" "::/EFI/OC/Kexts/CryptexFixup.kext/$f"
            done
        )
    fi
    mcopy -i "$CTMP/BOOT.img" -o "$CTMP/config.plist" ::/EFI/OC/config.plist

    mdir -i "$CTMP/BOOT.img" ::/EFI/OC/config.plist >/dev/null 2>&1 \
        || die "OpenCore boot image patch failed."
    if [[ $NEED_CRYPTEX -eq 1 ]]; then
        mdir -i "$CTMP/BOOT.img" ::/EFI/OC/Kexts/CryptexFixup.kext >/dev/null 2>&1 \
            || die "CryptexFixup injection failed."
    fi
    mv "$CTMP/BOOT.img" "$OC_BOOT_IMG"
    rm -rf "$CTMP"
    ok "OpenCore boot image ready"
fi

# ----------------------------------------------------------- macOS recovery image
RECOVERY_IMG="$WORK_DIR/${MACOS_VERSION}-recovery.img"
if [[ -f "$RECOVERY_IMG" ]]; then
    ok "Recovery image already present"
else
    info "Downloading macOS $MACOS_NAME recovery from Apple servers..."
    curl -fsSL -o macrecovery.py "$MACRECOVERY_URL"
    python3 macrecovery.py -b "$BOARD_ID" -m 00000000000000000 -os "$OS_ARG" download
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
    --vga vmware,memory=256 \
    --scsihw virtio-scsi-pci \
    --net0 "virtio,bridge=$BRIDGE" \
    --agent enabled=1 \
    --tablet 0

# Light configuration first, heavy disk imports last: if a slow storage
# stalls an import, the VM is still fully configured and easy to finish.
qm set "$VMID" --args "-device isa-applesmc,osk=\"$OSK\" -smbios type=2 -device qemu-xhci,id=xhci -device usb-kbd,bus=xhci.0 -device usb-tablet,bus=xhci.0 -global nec-usb-xhci.msi=off -global ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off $CPU_ARGS"
qm set "$VMID" --efidisk0 "$STORAGE:1,efitype=4m,pre-enrolled-keys=0"
qm set "$VMID" --virtio0 "$STORAGE:$DISK,cache=unsafe,discard=on"

# dd instead of import-from: qemu-img's zeroinit filter can hang forever on
# LVM-thin storage (D-state), while plain sequential writes go through fine.
# Prints the created volume id; fails when the storage has no local path.
import_raw() {
    local file="$1" size extents kib vol dev
    size="$(stat -c%s "$file")"
    extents=$(( (size + 4194303) / 4194304 ))   # 4 MiB LVM extents
    kib=$(( extents * 4096 ))
    vol="$(pvesm alloc "$STORAGE" "$VMID" '' "$kib" --format raw 2>/dev/null \
        | grep -o "'[^']*'" | tr -d "'" | tail -n1)"
    [[ -n "$vol" ]] || return 1
    dev="$(pvesm path "$vol" 2>/dev/null || true)"
    if [[ -z "$dev" || ! -e "$dev" ]]; then
        pvesm free "$vol" >/dev/null 2>&1 || true
        return 1
    fi
    dd if="$file" of="$dev" bs=4M conv=fsync status=progress </dev/null
    echo "$vol"
}

info "Importing the recovery disk (can take a while on slow storage)..."
RECOVERY_VOL="$(import_raw "$RECOVERY_IMG" || true)"
if [[ -n "$RECOVERY_VOL" ]]; then
    qm set "$VMID" --sata0 "$RECOVERY_VOL"
else
    # Storage without a writable local path (e.g. RBD): use qemu-img import
    warn "Storage has no direct path — falling back to qemu-img import"
    qm set "$VMID" --sata0 "$STORAGE:0,import-from=$RECOVERY_IMG"
fi

info "Attaching the OpenCore boot disk..."
OC_VOL="$(import_raw "$OC_BOOT_IMG" || true)"
if [[ -n "$OC_VOL" ]]; then
    qm set "$VMID" --sata1 "$OC_VOL"
else
    qm set "$VMID" --sata1 "$STORAGE:0,import-from=$OC_BOOT_IMG"
fi
qm set "$VMID" --boot order=sata1

ok "VM $VMID created"

if [[ "$START" == "1" ]]; then
    info "Starting VM $VMID..."
    qm start "$VMID"
    ok "VM started"
fi

# ----------------------------------------------------------------------- summary
echo
echo -e "${c_green}=========================================================${c_reset}"
echo -e "${c_green}  macOS $MACOS_NAME VM ready to install${c_reset}"
echo -e "${c_green}=========================================================${c_reset}"
echo
echo "  VM id      : $VMID"
echo "  Name       : $VM_NAME"
echo "  CPU        : $CORES cores (virtual: $CPU_MODEL)"
echo "  SMBIOS     : $SMBIOS_PRODUCT (random serial/MLB/UUID generated)"
if [[ $NEED_CRYPTEX -eq 1 ]]; then
    echo "  Note       : non-AVX2 host — OpenCore includes CryptexFixup;"
    echo "               macOS updates require full installers (no deltas)"
fi
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
echo "  5. Install macOS $MACOS_NAME (downloads from Apple, ~30-60 min)"
echo "  6. Once on the macOS desktop, make the VM standalone:"
echo "       curl -fsSL <this script's URL> | bash -s -- finalize $VMID"
echo
echo "  Until then, keep the OpenCore boot disk (sata1): the VM boots through it."
echo "  Remove everything:            qm destroy $VMID"
echo

}

main "$@"
