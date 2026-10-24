###############################################################################
# variables.tf — Toutes les variables d'entrée du projet
###############################################################################
#
# Les valeurs sont fournies par deux fichiers, chargés ensemble :
#
#   terraform.tfvars       (chargé automatiquement, NON versionné)
#     → connexion Proxmox, templates, réseau : commun à toutes les classes.
#
#   classes/<classe>.tfvars (passé avec -var-file, NON versionné)
#     → nom de la classe et liste des étudiants.
#
# Une variable sans « default » est obligatoire : Terraform refuse de
# continuer si elle n'est fournie par aucun fichier.
#
# Les blocs « validation » contrôlent les valeurs dès le `plan`, avant toute
# modification sur Proxmox.
###############################################################################


# =============================================================================
# 1. CONNEXION À PROXMOX                               (terraform.tfvars)
# =============================================================================

variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox : adresse INTERNE d'un nœud, port 8006 (ex. https://10.187.36.12:8006/)."
  type        = string
}

variable "proxmox_api_token" {
  description = "Token API au format terraform@pve!tf=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  type        = string

  # « sensitive » masque la valeur dans l'affichage de plan/apply et dans les
  # sorties. Elle reste toutefois en clair dans le fichier d'état
  # (terraform.tfstate.d/), d'où son exclusion de Git.
  sensitive = true
}

variable "node_name" {
  description = "Nœud Proxmox où sont créées les VM des étudiants. Les bridges étudiants doivent y exister."
  type        = string

  # Seul siohyp2 porte les bridges vmbr401… ; siohyp1 et siohyp3 n'en ont pas.
  default = "siohyp2"
}


# =============================================================================
# 2. TEMPLATES ET MODE DE CLONAGE                       (terraform.tfvars)
# =============================================================================

# Le cluster compte plusieurs nœuds : un template n'est pas forcément sur le
# nœud où l'on crée les VM. Pour chaque template, on indique donc son VMID ET
# le nœud qui le porte. Pour retrouver le nœud d'un template :
#   ls /etc/pve/nodes/*/qemu-server/<vmid>.conf
#
# La clé (sns, winsrv, wincli…) est libre : elle est référencée par le champ
# « template » de chaque VM dans var.lab_vms.
variable "templates" {
  description = "Clé libre => { vm_id du template, nœud qui le porte }"
  type = map(object({
    vm_id = number # VMID du template, ex. 404
    node  = string # nœud du cluster où se trouve sa configuration
  }))
}

# Clone lié ou clone complet ?
#
#   Clone lié (true) : la VM ne reçoit qu'un petit disque « différentiel »
#   qui stocke uniquement ce qu'elle modifie ; le reste est lu sur le disque
#   du template. Création en quelques secondes, très peu d'espace disque.
#   Contrainte : le template ne doit plus être modifié ni supprimé tant que
#   des clones en dépendent (Proxmox bloque la suppression).
#
#   Clone complet (false) : copie intégrale du disque. Plusieurs minutes et
#   plusieurs dizaines de Go par VM, mais la VM est totalement indépendante.
#
# Un clone lié vers un autre nœud n'est possible que si le disque du template
# est sur un stockage partagé (c'est le cas de NFS-NAS, en qcow2).
variable "linked_clone" {
  description = "true = clone lié (rapide, économe) ; false = clone complet vers clone_datastore"
  type        = bool
  default     = true
}

variable "clone_datastore" {
  description = "Stockage cible des clones complets (ignoré en clone lié). null = même stockage que le template."
  type        = string
  default     = null
}


# =============================================================================
# 3. RÉSEAU                                             (terraform.tfvars)
# =============================================================================
#
# Le réseau des étudiants existe déjà sur siohyp2 : UN bridge Linux par VLAN,
# et 5 bridges consécutifs par étudiant. Les bridges ne sont pas
# « VLAN-aware » : c'est le bridge lui-même qui porte le VLAN (bond0.401…),
# les cartes des VM n'ont donc pas de tag VLAN.
#
#   ETU01 : vmbr401 vmbr402 vmbr403 vmbr404 vmbr405
#   ETU02 : vmbr406 vmbr407 vmbr408 vmbr409 vmbr410
#   …
#   ETU38 : vmbr586 vmbr587 vmbr588 vmbr589 vmbr590
#
# Formule (calculée dans modules/student_lab/main.tf) :
#   bridge du VLAN n = vmbr( bridge_base + (etu - 1) × bridges_par_etudiant + n )
# =============================================================================

variable "bridge_base" {
  description = "Numéro de départ des bridges étudiants : 400 → le premier est vmbr401"
  type        = number
  default     = 400
}

variable "bridges_par_etudiant" {
  description = "Nombre de bridges (donc de VLAN) réservés à chaque étudiant"
  type        = number
  default     = 5
}

variable "wan_bridge" {
  description = "Bridge de l'interface « out » des SNS, commun à tous les étudiants"
  type        = string

  # vmbr134 = réseau « BTSSIO BYOD Wifi » (bond0.134), qui fournit l'accès
  # Internet du lycée.
  default = "vmbr134"
}

variable "wan_vlan_id" {
  description = "Tag VLAN à poser sur la carte WAN si le bridge est VLAN-aware ; null si aucun"
  type        = number
  default     = null
}


# =============================================================================
# 4. CONTENU D'UN LAB                    (valeur par défaut ou classes/*.tfvars)
# =============================================================================
#
# Liste des VM créées pour CHAQUE étudiant. La clé (sns, srv, cli…) sert de
# suffixe au nom de la VM (« dupont.alice-sns ») et de tag.
#
# Champs de chaque VM :
#   index         1 à 9, unique : dernier chiffre du VMID (voir vmid_base).
#   template      clé de var.templates à cloner.
#   nics          cartes réseau, DANS L'ORDRE :
#                   "wan"              → var.wan_bridge
#                   "vlan01".."vlan05" → bridges ETUxx-VLAN01..05 de l'étudiant
#                 Pour le SNS, l'ordre donne les interfaces out, in, dmz1, dmz2…
#   cores, memory processeurs et mémoire (Mo).
#   agent         true seulement si le template a le QEMU Guest Agent installé :
#                 sinon Terraform attend indéfiniment une adresse IP.
#   bios          "seabios" (BIOS classique) ou "ovmf" (UEFI).
#   scsi_hardware contrôleur de disque.
#
# ⚠ bios et scsi_hardware DOIVENT reprendre les valeurs du template :
#   le provider bpg impose ses propres valeurs par défaut au clone (seabios,
#   virtio-scsi-pci). Un Windows installé en UEFI cloné en seabios ne démarre
#   pas. Pour lire les valeurs d'un template :
#     grep -E '^(bios|scsihw)' /etc/pve/nodes/*/qemu-server/<vmid>.conf
# =============================================================================

variable "lab_vms" {
  description = "VM créées pour chaque étudiant (voir le commentaire au-dessus)"
  type = map(object({
    index         = number
    template      = string
    nics          = list(string)
    cores         = optional(number, 2)
    memory        = optional(number, 2048)
    agent         = optional(bool, false)
    bios          = optional(string, "seabios")
    scsi_hardware = optional(string, "virtio-scsi-single") # valeur des 3 templates actuels
  }))

  # Topologie par défaut du TP « contrôleur de domaine derrière un SNS » :
  #
  #              WAN (vmbr134)
  #                   │ out
  #               ┌───┴───┐
  #               │  SNS  │  template 404, BIOS classique
  #               └─┬───┬─┘
  #             in  │   │ dmz1
  #     VLAN01 ─────┘   └───── VLAN02
  #   192.168.56.0/24       172.16.10.0/24
  #        │                     │
  #   client Win11          serveur 2025
  #   (270, UEFI)           (267, UEFI)
  default = {
    sns = { index = 1, template = "sns", nics = ["wan", "vlan01", "vlan02"], cores = 1, memory = 2048 }
    srv = { index = 2, template = "winsrv", nics = ["vlan02"], cores = 2, memory = 4096, bios = "ovmf" }
    cli = { index = 3, template = "wincli", nics = ["vlan01"], cores = 2, memory = 4096, bios = "ovmf" }
  }

  # Refuse toute carte qui ne s'écrit pas "wan" ou "vlanNN" (ex. une faute de
  # frappe « vlan1 » au lieu de « vlan01 »).
  validation {
    condition = alltrue(flatten([
      for vm in values(var.lab_vms) : [for n in vm.nics : can(regex("^(wan|vlan[0-9]{2})$", n))]
    ]))
    error_message = "Chaque nic doit valoir \"wan\" ou \"vlanNN\" (ex. vlan01)."
  }
}

# Numérotation des VM : VMID = vmid_base + etu × 10 + index
#   ETU01 : 10011 (sns) 10012 (srv) 10013 (cli)
#   ETU07 : 10071 10072 10073
#   ETU38 : 10381 10382 10383
# Le VMID suffit donc à retrouver l'étudiant et le rôle de la VM. Choisir une
# base qui ne chevauche aucune VM existante du cluster.
variable "vmid_base" {
  description = "Base des VMID : VMID = vmid_base + etu × 10 + index"
  type        = number
  default     = 10000
}

variable "keyboard_layout" {
  description = "Disposition du clavier de la console noVNC (le provider impose en-us sinon)"
  type        = string
  default     = "fr"
}

variable "start_vms" {
  description = "Démarrer les VM juste après leur création"
  type        = bool

  # false par défaut : 38 étudiants × 10 Go de RAM = environ 380 Go si tout
  # démarre en même temps. Les étudiants allument leurs VM eux-mêmes.
  default = false
}


# =============================================================================
# 5. CLASSE ET ÉTUDIANTS                                (classes/<classe>.tfvars)
# =============================================================================

variable "classe" {
  description = "Nom court de la classe, posé en tag sur toutes ses VM (ex. sio2026)"
  type        = string
}

variable "pool_prefix" {
  description = "Préfixe des pools existants : pool = pool_prefix + login"
  type        = string
  default     = "SIO2026_"
}

# Table des étudiants : login => { etu = numéro ETUxx de ses bridges }.
#
# Le login est le nom du pool sans son préfixe (SIO2026_dupont.alice →
# "dupont.alice"). Le numéro etu relie l'étudiant à ses bridges ETUxx et
# détermine ses VMID.
#
# ⚠ Une fois les VM créées, ne plus changer le numéro d'un étudiant :
#   Terraform détruirait ses VM pour les recréer sur d'autres bridges.
variable "etudiants" {
  description = "login => { etu = numéro ETUxx de ses bridges, ctf = CTF propre à l'étudiant (facultatif) }"
  type = map(object({
    etu = number
    # Facultatif : CTF (1 à 5) de cet étudiant, s'il diffère de var.ctf.numero.
    # Changer ce numéro remplace son conteneur CTF par le CTF demandé.
    ctf = optional(number)
  }))

  # Deux étudiants sur le même numéro partageraient les mêmes VLAN et les
  # mêmes VMID : refusé.
  validation {
    condition     = length(distinct([for e in values(var.etudiants) : e.etu])) == length(var.etudiants)
    error_message = "Deux étudiants ont le même numéro etu."
  }

  # Le premier bridge est vmbr(bridge_base + 1) : il n'y a pas d'ETU00.
  validation {
    condition     = alltrue([for e in values(var.etudiants) : e.etu >= 1])
    error_message = "Les numéros etu commencent à 1."
  }

  validation {
    condition     = alltrue([for e in values(var.etudiants) : e.ctf == null ? true : (e.ctf >= 1 && e.ctf <= 5)])
    error_message = "Le champ ctf d'un étudiant vaut 1 à 5."
  }
}


# =============================================================================
# 6. CHALLENGE CTF (facultatif)                         (terraform.tfvars)
# =============================================================================
#
# Ajoute à chaque étudiant un conteneur LXC du challenge « 5 CTF pour
# Proxmox VE » (Damien SCONTRINO, CC BY-NC-SA 4.0), dans son pool et sur son
# VLAN. Détails : modules/student_lab/ctf.tf et docs/CTF.md.
#
# Prérequis sur le nœud ssh_host (= node_name) :
#   - ctf_creer.sh déposé dans node_dir (le script d'origine, non modifié) ;
#   - le modèle Debian 12 téléchargé (pveam) sur un stockage « vztmpl » ;
#   - la clé SSH publique de la VM Terraform dans ~root/.ssh/authorized_keys.
# =============================================================================

variable "ctf" {
  description = "Conteneur CTF de chaque étudiant (désactivé par défaut)"
  type = object({
    enabled = optional(bool, false)
    numero  = optional(number, 1) # CTF par défaut de la classe (1 à 5)
    index   = optional(number, 9) # VMID = vmid_base + etu × 10 + index → ETU07 = 10079

    # Conteneur (mêmes valeurs que ctf_creer.sh)
    template  = optional(string)            # "<stockage>:vztmpl/debian-12-standard_….tar.zst"
    datastore = optional(string, "NFS-NAS") # stockage acceptant « rootdir »
    disk_go   = optional(number, 8)
    memory    = optional(number, 512)
    cores     = optional(number, 1)

    # Réseau PENDANT l'installation : il faut Internet (paquets Debian)
    install_bridge    = optional(string)         # null = wan_bridge
    install_ip        = optional(string, "dhcp") # ou modèle "10.187.35.%d/24"
    install_ip_offset = optional(number, 150)    # adresse = offset + etu
    install_gateway   = optional(string)         # obligatoire si install_ip n'est pas dhcp
    install_dns       = optional(string)         # null = DNS du nœud

    # Réseau FINAL : VLAN de l'étudiant (même adresse pour tous, réseaux isolés)
    vlan    = optional(string, "vlan01") # vlan01 = LAN du client Windows
    ip      = optional(string, "192.168.56.50/24")
    gateway = optional(string, "192.168.56.254") # le SNS de l'étudiant
    dns     = optional(string)

    # Accès SSH au nœud pour lancer pct (installation)
    ssh_host        = optional(string) # adresse interne de node_name
    ssh_user        = optional(string, "root")
    ssh_private_key = optional(string, "~/.ssh/id_ed25519")
    node_dir        = optional(string, "/root/ctf") # contient ctf_creer.sh
  })
  default = {}

  validation {
    condition     = var.ctf.numero >= 1 && var.ctf.numero <= 5
    error_message = "ctf.numero vaut 1 à 5."
  }

  validation {
    condition     = !var.ctf.enabled || (var.ctf.template != null && var.ctf.ssh_host != null)
    error_message = "Avec ctf.enabled = true, renseigner ctf.template et ctf.ssh_host."
  }

  validation {
    condition     = can(regex("^vlan[0-9]{2}$", var.ctf.vlan))
    error_message = "ctf.vlan doit valoir vlanNN (ex. vlan01)."
  }

  validation {
    condition     = var.ctf.install_ip == "dhcp" || (strcontains(var.ctf.install_ip, "%d") && var.ctf.install_gateway != null)
    error_message = "ctf.install_ip vaut \"dhcp\", ou un modèle contenant %d (ex. 10.187.35.%d/24) avec install_gateway."
  }
}
