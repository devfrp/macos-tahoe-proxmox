# macOS Tahoe on Proxmox VE — one-command installer

> 🇫🇷 [Version française](README.fr.md)

Create a ready-to-install **macOS Tahoe (macOS 26)** virtual machine on **Proxmox VE** with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | bash
```

Run it **as root on the Proxmox host**. The script:

1. Checks the host (Proxmox VE, VT-x/AMD-V, **AVX2** — required by Tahoe)
2. Configures KVM (`ignore_msrs=1`, persistent)
3. Downloads the [OpenCore ISO](https://github.com/LongQT-sea/OpenCore-ISO) (boot loader)
4. Downloads the **official macOS Tahoe recovery** from Apple's servers ([macrecovery](https://github.com/acidanthera/OpenCorePkg))
5. Converts it and creates a fully configured VM (q35, OVMF, VirtIO disk & network)

## Requirements

- Proxmox VE **7.2 or later**
- Host CPU with **AVX2** (Intel Haswell+ / AMD Zen+) and virtualization enabled
- ~5 GB free on the ISO storage, plus the VM disk (80 GB by default)
- Internet access on the host **and** in the VM (the installer streams macOS from Apple)

## Options

Every setting can be overridden with environment variables:

```bash
curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | \
  VMID=990 CORES=8 RAM=16384 DISK=120 STORAGE=local-zfs bash
```

| Variable      | Default        | Description               |
|---------------|----------------|---------------------------|
| `VMID`        | next free id   | Proxmox VM id             |
| `VM_NAME`     | `macos-tahoe`  | VM name                   |
| `CORES`       | `4`            | CPU cores                 |
| `RAM`         | `8192`         | RAM in MiB                |
| `DISK`        | `80`           | Main disk size in GiB     |
| `STORAGE`     | `local-lvm`    | Storage for the VM disks  |
| `ISO_STORAGE` | `local`        | Storage for the ISOs      |
| `BRIDGE`      | `vmbr0`        | Network bridge            |
| `START`       | `1`            | Start the VM at the end (`0` to disable) |
| `CPU_MODEL`   | `Haswell-noTSX-IBRS` | Virtual CPU model presented to macOS |

## After the script

1. The VM starts automatically (unless `START=0`)
2. Open the **console**, let OpenCore boot **macOS Base System**
3. In **Disk Utility**, erase the large VirtIO disk (APFS, GUID partition map)
4. Quit Disk Utility, choose **Install macOS Tahoe** (download from Apple, 30–60 min, the VM reboots several times — always let OpenCore pick the default entry)
5. Once on the desktop, detach the recovery disk: `qm set <VMID> --delete sata0`

Keep the OpenCore ISO (`ide2`) attached — the VM boots through it.

## Troubleshooting

- **Virtual CPU**: the VM always uses a generic `Haswell-noTSX-IBRS` virtual CPU, so the same configuration works on any Intel or AMD host with AVX2. Advanced users on Intel can try `CPU_MODEL=host` for slightly better performance.
- **Boot loop / instant reset**: verify `cat /sys/module/kvm/parameters/ignore_msrs` returns `Y` (reboot the host after first install if needed).
- **No mouse/keyboard**: use the noVNC console; USB passthrough can be added afterwards.
- **Slow display**: normal, the VM has no GPU acceleration. GPU passthrough is possible but out of scope here.

## Uninstall

```bash
qm destroy <VMID>
rm -rf /root/macos-tahoe-installer
```

## Legal

macOS is licensed by Apple for use on Apple hardware only. This project is intended for testing and development; make sure your use complies with the [Apple EULA](https://www.apple.com/legal/sla/). No Apple software is redistributed here: the recovery image is downloaded directly from Apple's servers.

## Credits

- [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) — OpenCore image for Proxmox/KVM
- [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) — macrecovery
