# Labs étudiants SIO2026 sur Proxmox avec Terraform

Ce projet s'appuie sur **ce qui existe déjà** sur le Proxmox :

| Existant | Utilisation par Terraform |
|---|---|
| Pools `SIO2026_<login>` (avec les droits des étudiants) | les VMs de chaque étudiant sont rangées dans son pool → il les voit et les pilote avec ses droits actuels |
| Bridges `vmbr401…` sur `bond0.401…`, 5 par étudiant (`ETU01-VLAN01..05`) | les cartes des VMs sont branchées sur les bridges de l'étudiant (pas de tag VLAN : c'est le bridge qui porte le VLAN) |
| Templates du pool `TemplatesVM` | clonés pour chaque étudiant (clones liés par défaut) |

Terraform **ne crée ni compte, ni pool, ni bridge** : il crée uniquement les VMs.

## Ce que reçoit chaque étudiant

```
                 WAN (wan_bridge = vmbr134, BYOD Wifi)
                          │ out
                     ┌────┴────┐
                     │   SNS   │   Modele-SNS-4.33 (404)
                     └─┬─────┬─┘
                    in │     │ dmz1
     ETUxx-VLAN01      │     │      ETUxx-VLAN02
          ┌────────────┘     └────────────┐
   ┌──────┴───────┐               ┌───────┴──────┐
   │ client Win11 │ (270)         │ srv Win 2025 │ (267)
   └──────────────┘               └──────────────┘
```

| Élément | Formule | Exemple ETU02 |
|---|---|---|
| Bridges | `vmbr(400 + (etu-1)×5 + n)` | VLAN01 = vmbr406 … VLAN05 = vmbr410 |
| VMID | `10000 + etu×10 + index` | sns 10021, srv 10022, cli 10023 |
| Nom VM | `login-vm` | `martin.bilal-sns` |
| Tags | `sio2026`, `etu02`, `sns` | |

---

## 1. Côté Proxmox (une seule fois)

### a) Token API pour Terraform
Dans le shell d'un nœud :
```bash
pveum user add terraform@pve
pveum aclmod / -user terraform@pve -role Administrator
pveum user token add terraform@pve tf --privsep 0
```
Le secret n'est affiché qu'une fois : le noter pour `terraform.tfvars`.

### b) Vérifier les templates (cluster)
`qm config` ne voit que les VMs du nœud courant. Pour tout le cluster :
```bash
# Sur quel nœud est chaque template ?
ls /etc/pve/nodes/*/qemu-server/{404,267,270}.conf

# Config d'un template sur n'importe quel nœud
for id in 404 267 270; do
  f=$(ls /etc/pve/nodes/*/qemu-server/$id.conf)
  echo "== $f"; grep -E '^(template|scsi|sata|ide|virtio)[0-9]*:' "$f"
done

# Stockages : lesquels sont partagés (colonne shared) ?
pvesm status
```

**État vérifié du cluster (octobre 2026)**

| Template | VMID | Nœud | Disque |
|---|---|---|---|
| Modele-SNS-4.33 | 404 | siohyp1 | `NFS-NAS` qcow2 |
| SRV2025MODELE (Windows Server 2025) | 267 | siohyp2 | `NFS-NAS` qcow2, 50 Go |
| WIN11CLIENT (Windows 11 25H2) | 270 | siohyp2 | `NFS-NAS` qcow2, 70 Go |

Les bridges étudiants n'existent que sur **siohyp2** : toutes les VMs étudiantes y sont créées (`node_name = "siohyp2"`), en clones liés depuis NFS-NAS.
- **Clone lié** possible si le disque est en qcow2 (ex. `NFS-NAS:267/base-267-disk-1.qcow2`), sur lvm-thin ou ZFS. Sinon : `linked_clone = false` (plus lent, plus de disque).
- **Cluster** : dans `templates`, indique le nœud de chaque template ; `node_name` est le nœud où les VMs étudiantes sont créées (les bridges `vmbr4xx` doivent y exister). Un template sur stockage partagé (NFS-NAS) peut être cloné en clone lié vers un autre nœud ; un template sur stockage local ne peut l'être que sur son propre nœud (sinon `linked_clone = false`).
- **Windows** : templates sysprepés (generalize), sinon même SID sur tous les clones.

### c) Générer la liste des étudiants
`classes/sio2026.tfvars.example` ne contient qu'un exemple fictif : la vraie liste va dans `classes/sio2026.tfvars`, exclu du dépôt Git (données personnelles des étudiants). Pour l'obtenir directement depuis Proxmox :
```bash
bash scripts/genere-etudiants.sh SIO2026_ siohyp2
```
Aucun paquet à installer (le script utilise perl, fourni avec Proxmox). Il affiche le bloc `etudiants = { … }`, puis contrôle pour chaque étudiant que ses 5 bridges existent sur le nœud et que leur commentaire porte bien son numéro `ETUxx`. Il signale toute anomalie avec `!!`.

⚠️ **Point clé : `etu` doit correspondre aux bridges `ETUxx` attribués à l'étudiant.** Si ETU01 n'est pas `dupont.alice`, corrige les numéros avant le premier `apply`. Ils ne doivent plus changer ensuite.

---

## 2. Côté poste d'admin (là où tourne Terraform)

```bash
# Installation Terraform (Debian/Ubuntu)
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
. /etc/os-release
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $VERSION_CODENAME main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform

# Projet
cp terraform.tfvars.example terraform.tfvars                # endpoint, token, nœud, templates
cp classes/sio2026.tfvars.example classes/sio2026.tfvars    # étudiants + topologie

terraform init
terraform workspace new sio2026
terraform validate
```

### Test avec UN étudiant
Dans `classes/sio2026.tfvars`, ne garde qu'une ligne dans `etudiants`, puis :
```bash
terraform plan  -var-file=classes/sio2026.tfvars
terraform apply -var-file=classes/sio2026.tfvars
```
À contrôler dans Proxmox : les 3 VMs sont dans le pool `SIO2026_<login>`, leurs cartes réseau sont sur les bons `vmbr4xx`, l'étudiant les voit en se connectant avec son compte.

### Toute la classe
Remets la liste complète :
```bash
terraform apply -var-file=classes/sio2026.tfvars -parallelism=4
```
`-parallelism=4` évite les erreurs de verrou Proxmox (`can't lock file`) quand beaucoup de clones partent en même temps.

---

## 3. Opérations courantes

| Besoin | Commande |
|---|---|
| Voir bridges et VMIDs | `terraform output labs` |
| Ajouter un étudiant | ajouter sa ligne, `apply` (les autres ne bougent pas) |
| Retirer un étudiant | supprimer sa ligne, `apply` (ses 3 VMs sont supprimées, pas son pool) |
| Réinitialiser le SNS d'un étudiant | `terraform apply -var-file=classes/sio2026.tfvars -replace='module.lab["durand.chloe"].proxmox_virtual_environment_vm.vm["sns"]'` |
| Fin d'année | `terraform destroy -var-file=classes/sio2026.tfvars` |

Ne modifie pas ces VMs à la main dans Proxmox (matériel, réseau) : passe par les fichiers puis `apply`. Allumer, éteindre et faire des snapshots ne pose pas de problème.

---

## 4. Changer de topologie

Dans `classes/sio2026.tfvars`, la variable `lab_vms` décrit le lab d'un étudiant. `nics` accepte `"wan"` ou `"vlan01"` à `"vlan05"` (les bridges ETUxx-VLAN01..05). Pour le SNS, l'ordre des cartes donne `out`, `in`, `dmz1`, `dmz2`… Exemple avec une Kali en plus :
```hcl
# dans terraform.tfvars (285 = exemple, à adapter)
templates = {
  sns    = { vm_id = 404, node = "siohyp1" }
  winsrv = { vm_id = 267, node = "siohyp2" }
  wincli = { vm_id = 270, node = "siohyp2" }
  kali   = { vm_id = 285, node = "siohyp2" }
}

lab_vms = {
  sns  = { index = 1, template = "sns",    nics = ["wan", "vlan01", "vlan02", "vlan03"], cores = 1, memory = 2048 }
  srv  = { index = 2, template = "winsrv", nics = ["vlan02"], cores = 2, memory = 4096 }
  cli  = { index = 3, template = "wincli", nics = ["vlan01"], cores = 2, memory = 4096 }
  kali = { index = 4, template = "kali",   nics = ["vlan03"], cores = 2, memory = 4096 }
}
```

## 5. Dimensionnement

Topologie par défaut : 10 Go de RAM par étudiant, soit **~390 Go pour 39 étudiants** si tout tourne en même temps. Les VMs sont donc créées éteintes (`start_vms = false`).

## Limites

- Terraform déploie des VMs vierges : IPs, configuration du SNS et de l'AD restent au programme du TP.
- Code non exécuté sur ton Proxmox : `terraform validate` puis un `plan` à un étudiant d'abord.

## Machines Linux (branche `machines-linux`)

Chaque étudiant reçoit, en plus du SNS, du serveur et du client Windows,
deux VM Linux branchées sur son **VLAN01** (192.168.56.0/24, le LAN du
client Windows, derrière l'interface *in* du SNS) :

| Rôle | Template | VMID (ETU01) | Nom |
|---|---|---|---|
| `mint` | 280 `linuxmintmodele` | 10014 | `<login>-mint` |
| `kali` | 283 `kalilinuxmodele` | 10015 | `<login>-kali` |

Templates vérifiés (24/10/2026) : tous deux sur **siohyp2**, BIOS classique
(seabios), contrôleur `virtio-scsi-single`, disque qcow2 de 80 Go sur
NFS-NAS : clones liés possibles, aucun réglage particulier dans `lab_vms`.

Sur une classe déjà déployée, le `plan` ne propose que les ajouts
(`76 to add` pour 38 étudiants) : les VM existantes ne sont pas modifiées.
Mémoire : +6 Go par étudiant si tout est allumé.

## Serveur Mutillidae (branche `serveur-mutillidae`)

Chaque étudiant reçoit une sixième VM, clone du template 286
`srvmutillidaemodele` (Linux Mint + Docker + OWASP Mutillidae II) :

| Rôle | Template | VLAN | VMID (ETU01) | Nom |
|---|---|---|---|---|
| `mutillidae` | 286 `srvmutillidaemodele` | **VLAN02** (DMZ, 172.16.10.0/24), avec le serveur Windows | 10016 | `<login>-mutillidae` |

Application **volontairement vulnérable** : elle n'est joignable que depuis
le réseau de l'étudiant, derrière son SNS. Depuis le LAN (client, Kali),
l'étudiant doit ouvrir les flux HTTP/HTTPS vers elle sur son firewall.

Sur une classe déployée, le `plan` ne propose que les ajouts (`39 to add`
pour 39 labs). Mémoire : +4 Go par étudiant si tout est allumé.
