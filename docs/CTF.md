# Challenge CTF dans le lab de chaque étudiant

Branche `ctf-challenge` : adaptation à ce projet Terraform du challenge
[« 5 CTF pour Proxmox VE »](https://github.com/SCONTRINO-Hub/challenge-5-ctf-proxmox)
de Damien SCONTRINO (licence **CC BY-NC-SA 4.0**).

Avec `ctf.enabled = true`, chaque étudiant reçoit, en plus de ses 3 VM, un
**conteneur LXC CTF** :

| | Script d'origine (`ctf_creer.sh`) | Ici (Terraform) |
|---|---|---|
| Création | menu interactif, sur le nœud | `terraform apply`, comme les VM |
| Rangement | aucun pool | **pool de l'étudiant** `SIO2026_<login>` |
| Réseau | pont commun, `<préfixe>.1nn` | installé sur le WAN, puis **VLAN01 de l'étudiant**, `192.168.56.50` |
| ID | `BASE + n` | `10000 + ETU × 10 + 9` (ETU07 → 10079) |
| Numéros | 1 à 38 | **1 à 40** (`ctf.etu_max`) : limite relevée dans la copie des scripts CTF3 et CTF5 |
| Nom | `CTFx-Etudiantnn` | identique |
| Flags | selon le numéro d'étudiant | selon le **numéro ETU** : les corrigés du challenge restent valables |
| Changer de CTF | progression automatique | l'enseignant change le numéro et lance `apply` |
| Suppression | menu | `terraform destroy`, `-replace`, ou retrait de l'étudiant |

Le script d'origine **n'est ni modifié ni recopié** : `scripts/ctf_installer.sh`
y lit le script d'installation du CTF choisi (bloc base64) et refait, pour un
seul conteneur, son étape de création.

## Comment ça marche

```
terraform apply
 ├─ terraform_data.ctf_outils           (1 fois)  SSH → nœud : dépose ctf_installer.sh,
 │                                                vérifie que ctf_creer.sh est là
 └─ pour chaque étudiant (module student_lab, fichier ctf.tf)
     ├─ proxmox_virtual_environment_container.ctf  API Proxmox : conteneur Debian 12
     │      non privilégié, dans le pool, carte sur le WAN (Internet pour les paquets)
     └─ terraform_data.ctf_install                SSH → nœud : ctf_installer.sh
            1. attend Internet dans le conteneur
            2. pct push + pct exec du script du CTF, avec le numéro ETU
            3. restreint les droits des flags
            4. rapatrie les fiches dans /root/ctf/ctf_resultats/CTFn/ (sur le nœud)
            5. pct set : carte basculée sur le VLAN de l'étudiant, puis ARRÊT
               (l'étudiant l'allume à la demande ; ctf.allume = true pour le laisser démarré)
```

Pourquoi SSH ? `pct push` et `pct exec` (copier un fichier dans un conteneur,
y lancer une commande) n'existent pas dans l'API Proxmox : il faut les
exécuter sur le nœud qui porte le conteneur.

## Prérequis (une fois)

Sur **siohyp2** (le nœud des étudiants) :

```bash
# 1. Le script du challenge, non modifié
mkdir -p /root/ctf && cd /root/ctf
wget https://github.com/SCONTRINO-Hub/challenge-5-ctf-proxmox/releases/latest/download/ctf_creer.sh
bash ctf_creer.sh --version          # comparer l'empreinte avec la page de la release

# 2. Le modèle Debian 12, sur un stockage qui accepte les modèles de conteneur
pvesm status --content vztmpl        # stockages possibles (ex. templates-OCI)
pveam update && pveam available --section system | grep debian-12
pveam download templates-OCI debian-12-standard_12.12-1_amd64.tar.zst   # nom exact affiché ci-dessus
pvesm list templates-OCI --content vztmpl                               # → valeur de ctf.template

# 3. Un stockage pour les disques des conteneurs
pvesm status --content rootdir       # → valeur de ctf.datastore
```

Sur la **VM Terraform** :

```bash
ssh-keygen -t ed25519                       # si pas encore de clé
ssh-copy-id root@<IP-interne-siohyp2>       # clé autorisée sur le nœud
ssh root@<IP-interne-siohyp2> pct list      # doit répondre sans mot de passe
```

Puis, dans `terraform.tfvars`, décommenter et compléter le bloc `ctf`.

## Déploiement

```bash
git switch ctf-challenge
terraform init
terraform test                                         # tests sans Proxmox (mock)
terraform plan -var-file=classes/sio2026.tfvars \
  -target='module.lab["<un.login>"]' -out=ctf.tfplan   # 1 conteneur + 1 installation
terraform apply ctf.tfplan                             # quelques minutes (paquets)
```

Contrôles sur le nœud :

```bash
pct config 10019                          # pool, net0 sur vmbr401, ip=192.168.56.50/24
ls /root/ctf/ctf_resultats/CTF1/          # fiche(s) de l'étudiant
tail /var/log/ctf_terraform.log           # journal (600 : contient les flags)
```

Depuis le client Windows de l'étudiant : `Test-NetConnection 192.168.56.50 -Port 22`.

Puis la classe entière : `terraform plan … -out=… && terraform apply -parallelism=4 …`.
Les VM existantes ne sont pas modifiées : seuls les conteneurs et leurs
installations sont ajoutés.

## Exploitation

| Besoin | Action |
|---|---|
| CTF de toute la classe | `ctf.numero` dans `terraform.tfvars` |
| CTF d'un étudiant | `"<login>" = { etu = 7, ctf = 3 }` dans `classes/sio2026.tfvars` |
| Appliquer un changement de CTF | `plan` (conteneur *replaced*) puis `apply` : l'ancien est détruit, le nouveau installé |
| Remettre un CTF à zéro | `apply -replace='module.lab["<login>"].proxmox_virtual_environment_container.ctf[0]'` |
| Installation ratée | même `-replace` : conteneur neuf et réinstallation (un script relancé sur un conteneur à moitié installé n'est pas fiable) |
| Retirer le challenge | `ctf.enabled = false` puis `apply` : conteneurs supprimés, VM intactes |
| Flags de la classe | `/root/ctf/ctf_resultats/` sur le nœud (ou les corrigés du challenge, par numéro ETU) |

## Points d'attention

- **Réseau d'installation.** Le conteneur passe quelques minutes sur le WAN
  (vmbr134, réseau BYOD) pour télécharger ses paquets, avec ses services
  vulnérables déjà démarrés. Pour l'éviter, utiliser un pont d'installation
  dédié avec NAT (`ctf.install_bridge`).
- **DHCP du WAN.** Si le WAN n'a pas de DHCP, utiliser `install_ip =
  "10.187.35.%d/24"` (adresse = 150 + ETU) avec `install_gateway`, en
  vérifiant que la plage .151 à .188 est libre.
- **Adresse affichée dans la fiche CTF1.** Le script du CTF1 note l'adresse
  du conteneur au moment de l'installation : celle du réseau d'installation,
  pas 192.168.56.50.
- **Après l'installation, plus d'Internet** dans le conteneur tant que le SNS
  de l'étudiant n'est pas configuré (passerelle 192.168.56.254). Les CTF n'en
  ont pas besoin pour fonctionner.
- **Progression automatique** du script d'origine : non reprise. Elle détruit
  et recrée des conteneurs hors de Terraform, qui perdrait leur trace.
- **Énoncés.** Remplacer `${TARGET_IP}` par `192.168.56.50` pour tous les
  étudiants (réseaux isolés).
- **Corrigés.** Flags identiques au script d'origine pour un même numéro :
  l'étudiant ETU07 a les flags de l'« étudiant 7 » des corrigés. Les corrigés
  PDF s'arrêtent à 38 : pour ETU39 et ETU40, les flags sont dans
  `/root/ctf/ctf_resultats/` (calculés par la même formule).
- **Numéros 39 et 40.** Les scripts du CTF3 et du CTF5 refusent les numéros
  supérieurs à 38. `ctf_installer.sh` relève cette limite à `ctf.etu_max`
  (40) dans la copie qu'il installe, sans modifier `ctf_creer.sh`. Au-delà,
  le `plan` s'arrête avec la liste des étudiants concernés.
- **Droits du token.** Créer un conteneur avec `nesting` est autorisé au token
  `terraform@pve` pour un conteneur non privilégié ; à vérifier au premier essai.

## Fichiers de la branche

| Fichier | Rôle |
|---|---|
| `modules/student_lab/ctf.tf` | conteneur + installation, pour un étudiant |
| `scripts/ctf_installer.sh` | installation d'un conteneur, exécutée sur le nœud |
| `variables.tf` | variable `ctf`, champ `ctf` facultatif par étudiant |
| `main.tf` | dépôt de l'installateur sur le nœud, paramètres du module |
| `outputs.tf`, `modules/student_lab/outputs.tf` | conteneur CTF dans `terraform output labs` |
| `tests/ctf.tftest.hcl` | tests sans Proxmox |
| `terraform.tfvars.example` | bloc `ctf` commenté |
