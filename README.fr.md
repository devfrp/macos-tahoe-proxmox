# macOS Tahoe sur Proxmox VE — installation en une commande

> 🇬🇧 [English version](README.md)

Crée une machine virtuelle **macOS Tahoe (macOS 26)** prête à installer sur **Proxmox VE** avec une seule commande :

```bash
curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | bash
```

À lancer **en root sur l'hôte Proxmox**. Le script :

1. Vérifie l'hôte (Proxmox VE, VT-x/AMD-V) et **choisit le meilleur CPU virtuel que l'hôte supporte** — ça fonctionne sur n'importe quel CPU Intel ou AMD, avec ou sans AVX2
2. Configure KVM (`ignore_msrs=1`, persistant)
3. Télécharge l'[ISO OpenCore](https://github.com/LongQT-sea/OpenCore-ISO) (chargeur de démarrage) ; sur les hôtes sans AVX2, il injecte automatiquement [CryptexFixup](https://github.com/acidanthera/CryptexFixup) pour que Tahoe s'installe quand même
4. Télécharge la **recovery officielle macOS Tahoe** depuis les serveurs Apple ([macrecovery](https://github.com/acidanthera/OpenCorePkg))
5. La convertit et crée une VM entièrement configurée (q35, OVMF, disque et réseau VirtIO)

## Prérequis

- Proxmox VE **7.2 ou plus récent**
- N'importe quel CPU hôte Intel/AMD 64 bits avec virtualisation activée et au moins **SSE4.2** (AVX2 recommandé — sans lui, macOS tourne sur ses fichiers système Rosetta non-AVX2 et les mises à jour passent par des installeurs complets)
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
| `CPU_MODEL`   | auto            | Modèle de CPU virtuel présenté à macOS (choisi selon les capacités de l'hôte) |

## Après le script

1. La VM démarre automatiquement (sauf si `START=0`)
2. Ouvrir la **console**, laisser OpenCore démarrer **macOS Base System**
3. Dans **Utilitaire de disque**, effacer le grand disque VirtIO (APFS, table GUID)
4. Quitter l'utilitaire, choisir **Installer macOS Tahoe** (téléchargement depuis Apple, 30–60 min, la VM redémarre plusieurs fois — toujours laisser OpenCore choisir l'entrée par défaut)
5. Une fois sur le bureau, détacher le disque de recovery : `qm set <VMID> --delete sata0`

Garder l'ISO OpenCore (`ide2`) attachée : la VM démarre à travers elle.

## Rendre la VM autonome (une commande)

Une fois macOS installé, lancer ceci **sur l'hôte Proxmox** — ça copie OpenCore sur la partition EFI de la VM, détache les médias d'installation et redémarre la VM depuis son disque :

```bash
curl -fsSL https://raw.githubusercontent.com/devfrp/macos-tahoe-proxmox/main/install.sh | bash -s -- finalize <VMID>
```

<details>
<summary>Alternative manuelle (depuis macOS)</summary>

```bash
sudo diskutil mount disk0s1
cp -R /Volumes/LongQT-OpenCore/EFI_RELEASE/EFI /Volumes/EFI/
```

Puis sur l'hôte : `qm set <VMID> --delete ide2 --delete sata0 && qm set <VMID> --boot order=virtio0`
</details>

## iCloud / iMessage (optionnel)

Les services Apple demandent un numéro de série unique et un hyperviseur masqué :

1. Générer un numéro de série avec [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) (modèle `iMacPro1,1`) dans `/Volumes/EFI/EFI/OC/config.plist`
2. Ajouter [VMHide](https://github.com/Carnations-Botanica/VMHide) dans `EFI/OC/Kexts` et dans `config.plist`, avec `vmhState=enabled` dans les boot-args
3. Redémarrer la VM avant de se connecter

Utiliser un numéro de série que la page de garantie Apple déclare **invalide**, et garder en tête que se connecter aux services Apple depuis une VM peut enfreindre les conditions d'Apple.

## Dépannage

- **CPU virtuel** : le script choisit automatiquement un CPU virtuel Intel générique selon ce que l'hôte peut fournir (`Haswell-noTSX-IBRS` avec AVX2, `SandyBridge-IBRS` avec AVX seul, `Nehalem-IBRS` avec SSE4.2), donc la même commande fonctionne sur n'importe quel hôte Intel ou AMD. Les utilisateurs avancés peuvent forcer un modèle avec `CPU_MODEL=...` (ex. `CPU_MODEL=host`).
- **Hôte sans AVX2** : la VM démarre via une ISO OpenCore reconstruite (`*-cryptex.iso`) contenant CryptexFixup. Les mises à jour delta de macOS ne sont pas disponibles ; mettre à jour via les installeurs complets.
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
