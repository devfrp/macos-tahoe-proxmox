# macOS Tahoe sur Proxmox VE — installation en une commande

> 🇬🇧 [English version](README.md)

Crée une machine virtuelle **macOS Tahoe (macOS 26)** prête à installer sur **Proxmox VE** avec une seule commande :

```bash
curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | bash
```

À lancer **en root sur l'hôte Proxmox**. Le script :

1. Vérifie l'hôte (Proxmox VE, VT-x/AMD-V, **AVX2** — requis par Tahoe)
2. Configure KVM (`ignore_msrs=1`, persistant)
3. Télécharge l'[ISO OpenCore](https://github.com/LongQT-sea/OpenCore-ISO) (chargeur de démarrage)
4. Télécharge la **recovery officielle macOS Tahoe** depuis les serveurs Apple ([macrecovery](https://github.com/acidanthera/OpenCorePkg))
5. La convertit et crée une VM entièrement configurée (q35, OVMF, disque et réseau VirtIO)

## Prérequis

- Proxmox VE **7.2 ou plus récent**
- CPU hôte avec **AVX2** (Intel Haswell+ / AMD Zen+) et virtualisation activée
- ~5 Go libres sur le stockage ISO, plus le disque de la VM (80 Go par défaut)
- Accès internet sur l'hôte **et** dans la VM (l'installeur télécharge macOS depuis Apple)

## Options

Chaque réglage est modifiable par variable d'environnement :

```bash
curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | \
  VMID=990 CORES=8 RAM=16384 DISK=120 STORAGE=local-zfs bash
```

| Variable      | Défaut          | Description                    |
|---------------|-----------------|--------------------------------|
| `VMID`        | prochain id libre | Id de la VM Proxmox          |
| `VM_NAME`     | `macos-tahoe`   | Nom de la VM                   |
| `CORES`       | `4`             | Cœurs CPU                      |
| `RAM`         | `8192`          | RAM en Mio                     |
| `DISK`        | `80`            | Taille du disque principal (Gio) |
| `STORAGE`     | `local-lvm`     | Stockage des disques VM        |
| `ISO_STORAGE` | `local`         | Stockage des ISO               |
| `BRIDGE`      | `vmbr0`         | Pont réseau                    |
| `START`       | `1`             | Démarrer la VM à la fin (`0` pour désactiver) |
| `CPU_MODEL`   | `Haswell-noTSX-IBRS` | Modèle de CPU virtuel présenté à macOS |

## Après le script

1. La VM démarre automatiquement (sauf si `START=0`)
2. Ouvrir la **console**, laisser OpenCore démarrer **macOS Base System**
3. Dans **Utilitaire de disque**, effacer le grand disque VirtIO (APFS, table GUID)
4. Quitter l'utilitaire, choisir **Installer macOS Tahoe** (téléchargement depuis Apple, 30–60 min, la VM redémarre plusieurs fois — toujours laisser OpenCore choisir l'entrée par défaut)
5. Une fois sur le bureau, détacher le disque de recovery : `qm set <VMID> --delete sata0`

Garder l'ISO OpenCore (`ide2`) attachée : la VM démarre à travers elle.

## Dépannage

- **CPU virtuel** : la VM utilise toujours un CPU virtuel générique `Haswell-noTSX-IBRS`, donc la même configuration fonctionne sur n'importe quel hôte Intel ou AMD avec AVX2. Les utilisateurs avancés sur Intel peuvent essayer `CPU_MODEL=host` pour un peu plus de performance.
- **Boot en boucle / reset immédiat** : vérifier que `cat /sys/module/kvm/parameters/ignore_msrs` renvoie `Y` (redémarrer l'hôte après la première installation si besoin).
- **Pas de souris/clavier** : utiliser la console noVNC ; un passthrough USB peut être ajouté ensuite.
- **Affichage lent** : normal, la VM n'a pas d'accélération GPU. Le passthrough GPU est possible mais hors périmètre ici.

## Désinstallation

```bash
qm destroy <VMID>
rm -rf /root/macos-tahoe-installer
```

## Mentions légales

macOS est sous licence Apple pour du matériel Apple uniquement. Ce projet est destiné aux tests et au développement ; assurez-vous que votre usage respecte le [CLUF Apple](https://www.apple.com/legal/sla/). Aucun logiciel Apple n'est redistribué ici : l'image de recovery est téléchargée directement depuis les serveurs Apple.

## Crédits

- [LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO) — image OpenCore pour Proxmox/KVM
- [acidanthera/OpenCorePkg](https://github.com/acidanthera/OpenCorePkg) — macrecovery
