# ---------------------------------------------------------------------------
# Connexion Proxmox (terraform.tfvars)
# ---------------------------------------------------------------------------
variable "proxmox_endpoint" {
  description = "URL de l'API Proxmox, ex. https://pve.lycee.local:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "Token API, format terraform@pve!tf=xxxxxxxx-xxxx-..."
  type        = string
  sensitive   = true
}

variable "node_name" {
  description = "Nœud Proxmox où seront créées les VMs des étudiants (les bridges étudiants doivent y exister)"
  type        = string
  default     = "siohyp2"
}

# ---------------------------------------------------------------------------
# Templates existants (pool TemplatesVM) — cluster : préciser le nœud de chacun
# ---------------------------------------------------------------------------
variable "templates" {
  description = "Clé libre => { vm_id du template, nœud qui le porte }"
  type = map(object({
    vm_id = number
    node  = string
  }))
}

variable "linked_clone" {
  description = <<-EOT
    true  = clone lié (rapide, peu de disque). Possible si le disque du template est
            sur un stockage partagé (ex. NFS-NAS en qcow2), ou si les VMs sont créées
            sur le même nœud que le template.
    false = clone complet (copie intégrale du disque, vers clone_datastore).
  EOT
  type        = bool
  default     = true
}

variable "clone_datastore" {
  description = "Stockage cible des clones complets (ignoré pour les clones liés). null = même stockage que le template."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Réseau existant : un bridge par VLAN, N bridges consécutifs par étudiant
#   ETU01 : vmbr401..vmbr405, ETU02 : vmbr406..vmbr410, ...
#   bridge = vmbr(bridge_base + (etu - 1) * bridges_par_etudiant + n°VLAN)
# ---------------------------------------------------------------------------
variable "bridge_base" {
  type    = number
  default = 400
}

variable "bridges_par_etudiant" {
  type    = number
  default = 5
}

variable "wan_bridge" {
  description = "Bridge de l'interface 'out' des SNS (commun à tous)"
  type        = string
  default     = "vmbr134"
}

variable "wan_vlan_id" {
  description = "Tag VLAN sur le bridge WAN, null si aucun"
  type        = number
  default     = null
}

# ---------------------------------------------------------------------------
# Contenu d'un lab (identique pour chaque étudiant)
# ---------------------------------------------------------------------------
variable "lab_vms" {
  description = <<-EOT
    VMs déployées pour CHAQUE étudiant.
    - index    : 1..9, unique, sert au calcul du VMID
    - template : clé de var.templates
    - nics     : liste ordonnée : "wan" ou "vlan01".."vlan05" (= ETUxx-VLAN01..05).
                 Pour le SNS, l'ordre donne out, in, dmz1, dmz2...
  EOT
  type = map(object({
    index    = number
    template = string
    nics     = list(string)
    cores    = optional(number, 2)
    memory   = optional(number, 2048)
    agent    = optional(bool, false)
    # Le provider impose ses valeurs par défaut au clone : elles doivent
    # reprendre celles du template (qm config <id> | grep -E 'bios|scsihw').
    bios          = optional(string, "seabios")         # "ovmf" pour un template UEFI
    scsi_hardware = optional(string, "virtio-scsi-single") # scsihw des 3 templates
  }))
  default = {
    sns = { index = 1, template = "sns", nics = ["wan", "vlan01", "vlan02"], cores = 1, memory = 2048 }
    srv = { index = 2, template = "winsrv", nics = ["vlan02"], cores = 2, memory = 4096, bios = "ovmf" }
    cli = { index = 3, template = "wincli", nics = ["vlan01"], cores = 2, memory = 4096, bios = "ovmf" }
  }

  validation {
    condition = alltrue(flatten([
      for vm in values(var.lab_vms) : [for n in vm.nics : can(regex("^(wan|vlan[0-9]{2})$", n))]
    ]))
    error_message = "Chaque nic doit valoir \"wan\" ou \"vlanNN\" (ex. vlan01)."
  }
}

variable "vmid_base" {
  description = "VMID = vmid_base + etu * 10 + index (ETU07 : 10071, 10072, 10073)"
  type        = number
  default     = 10000
}

variable "keyboard_layout" {
  description = "Clavier de la console noVNC"
  type        = string
  default     = "fr"
}

variable "start_vms" {
  description = "Démarrer les VMs après création"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Classe et étudiants (classes/<classe>.tfvars)
# ---------------------------------------------------------------------------
variable "classe" {
  description = "Nom court de la classe, utilisé en tag (ex. sio2026)"
  type        = string
}

variable "pool_prefix" {
  description = "Préfixe des pools existants : pool = pool_prefix + login"
  type        = string
  default     = "SIO2026_"
}

variable "etudiants" {
  description = "login (tel que dans le nom du pool) => { etu = numéro ETUxx de ses bridges }"
  type = map(object({
    etu = number
  }))

  validation {
    condition     = length(distinct([for e in values(var.etudiants) : e.etu])) == length(var.etudiants)
    error_message = "Deux étudiants ont le même numéro etu."
  }

  validation {
    condition     = alltrue([for e in values(var.etudiants) : e.etu >= 1])
    error_message = "Les numéros etu commencent à 1."
  }
}
