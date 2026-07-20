# macOS Tahoe on Proxmox VE — one-command installer

> 🇫🇷 [Version française](README.fr.md)

Create a ready-to-install **macOS Tahoe (macOS 26)** virtual machine on **Proxmox VE** with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | bash
```

Run it **as root on the Proxmox host**. The script:

1. Checks the host (Proxmox VE, VT-x/AMD-V) and **picks the best virtual CPU the host supports** — it works on any Intel or AMD CPU, with or without AVX2
2. Configures KVM (`ignore_msrs=1`, persistent)
3. Downloads the [OpenCore ISO](https://github.com/LongQT-sea/OpenCore-ISO) (boot loader), generates a fresh random SMBIOS (serial, MLB, UUID) matching the chosen macOS version, and patches it in; on non-AVX2 hosts it also injects [CryptexFixup](https://github.com/acidanthera/CryptexFixup) so Tahoe still installs
4. Downloads the **official macOS Tahoe recovery** from Apple's servers ([macrecovery](https://github.com/acidanthera/OpenCorePkg))
5. Converts it and creates a fully configured VM (q35, OVMF, VirtIO disk & network)

## Requirements

- Proxmox VE **7.2 or later**
- Any 64-bit Intel/AMD host CPU with virtualization enabled and at least **SSE4.2** (AVX2 recommended — without it, macOS runs on its non-AVX2 Rosetta system files and updates need full installers)
- ~5 GB free on the ISO storage, plus the VM disk (80 GB by default)
- Internet access on the host **and** in the VM (the installer streams macOS from Apple)

## Options

Run interactively (in a terminal), the script asks for the essentials: **macOS version** (Tahoe, Sequoia, Sonoma, Ventura), **storage**, **RAM** and **disk size** — press Enter to accept the defaults. Every setting can also be given as an environment variable, which skips its question (and without a terminal the defaults apply — automation stays non-interactive):

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
| `CPU_MODEL`   | auto           | Virtual CPU model presented to macOS (auto-picked from host capabilities) |
| `VERSION`     | `tahoe`        | macOS version: `tahoe`, `sequoia`, `sonoma`, `ventura` |
| `INTERACTIVE` | `1`            | `0` disables the terminal questions |

## After the script

1. The VM starts automatically (unless `START=0`)
2. Open the **console**, let OpenCore boot **macOS Base System**
3. In **Disk Utility**, erase the large VirtIO disk (APFS, GUID partition map)
4. Quit Disk Utility, choose **Install macOS Tahoe** (download from Apple, 30–60 min, the VM reboots several times — always let OpenCore pick the default entry)
5. Once on the desktop, detach the recovery disk: `qm set <VMID> --delete sata0`

Keep the OpenCore boot disk (`sata1`) attached — the VM boots through it.

## Make the VM standalone (one command)

Once macOS is installed, run this **on the Proxmox host** — it copies OpenCore to the VM's own EFI partition, detaches the installer media and reboots the VM from its disk:

```bash
curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | bash -s -- finalize <VMID>
```

<details>
<summary>Manual alternative (from inside macOS)</summary>

```bash
sudo diskutil mount disk0s1
cp -R /Volumes/LongQT-OpenCore/EFI_RELEASE/EFI /Volumes/EFI/
```

Then on the host: `qm set <VMID> --delete ide2 --delete sata0 --delete sata1 && qm set <VMID> --boot order=virtio0`
</details>

## iCloud / iMessage (optional)

The script already generates a random SMBIOS (serial, MLB, UUID) per VM — enough for the installer and Software Update to work. Apple services (iCloud/iMessage) additionally need a hidden hypervisor:

1. Add [VMHide](https://github.com/Carnations-Botanica/VMHide) to `EFI/OC/Kexts` and to `config.plist`, with `vmhState=enabled` in boot-args
2. Reboot the VM before signing in

Check the generated serial on Apple's coverage page first — signing in to Apple services from a VM may violate Apple's terms, and a serial that happens to resemble a real device should be regenerated with [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS).

## Troubleshooting

- **Virtual CPU**: the script auto-selects a generic Intel virtual CPU matching what the host can provide (`Haswell-noTSX-IBRS` with AVX2, `SandyBridge-IBRS` with AVX only, `Nehalem-IBRS` with SSE4.2), so the same command works on any Intel or AMD host. Advanced users can force a model with `CPU_MODEL=...` (e.g. `CPU_MODEL=host`).
- **"An error occurred preparing the software update"**: the stock OpenCore ISO ships a placeholder SMBIOS (`iMac19,1`, all-zero serial) that Apple's installer rejects. The script now always generates a real one matching the chosen macOS version — delete the cached `/root/macos-tahoe-installer/opencore-boot-<version>.img` and re-run to regenerate it if you built the VM before this fix.
- **Non-AVX2 host**: the VM boots through a small OpenCore boot disk (`sata1`) carrying CryptexFixup — no ISO rebuild involved. The `finalize` step folds it into the VM's own EFI partition. macOS delta updates are not available; update via full installers.
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
