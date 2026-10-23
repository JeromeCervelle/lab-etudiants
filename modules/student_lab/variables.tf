###############################################################################
# modules/student_lab/variables.tf — Entrées du module
###############################################################################
#
# Ce sont les paramètres transmis par le bloc module "lab" du main.tf racine.
# Leur sens détaillé est documenté dans le variables.tf racine : ici, on ne
# rappelle que leur rôle dans le module.
###############################################################################

# --- Identité de l'étudiant ---------------------------------------------------

variable "classe" {
  description = "Nom court de la classe, posé en tag (ex. sio2026)"
  type        = string
}

variable "login" {
  description = "Login de l'étudiant, utilisé dans le nom des VM (ex. dupont.alice)"
  type        = string
}

variable "etu" {
  description = "Numéro ETUxx de l'étudiant : détermine ses bridges et ses VMID"
  type        = number
}

variable "pool_id" {
  description = "Pool Proxmox existant de l'étudiant (ex. SIO2026_dupont.alice)"
  type        = string
}

# --- Création des VM ----------------------------------------------------------

variable "node_name" {
  description = "Nœud où créer les VM"
  type        = string
}

variable "templates" {
  description = "Clé => { vm_id, node } de chaque template"
  type = map(object({
    vm_id = number
    node  = string
  }))
}

variable "linked_clone" {
  description = "true = clone lié, false = clone complet"
  type        = bool
}

variable "clone_datastore" {
  description = "Stockage cible des clones complets (null = celui du template)"
  type        = string
  default     = null
}

variable "start_vms" {
  description = "Démarrer les VM après création"
  type        = bool
}

variable "keyboard_layout" {
  description = "Clavier de la console noVNC"
  type        = string
}

variable "vmid_base" {
  description = "Base des VMID : vmid_base + etu × 10 + index"
  type        = number
}

# Même structure que var.lab_vms à la racine. Les valeurs par défaut des champs
# optionnels sont répétées ici pour que le module reste utilisable seul.
variable "lab_vms" {
  description = "VM à créer pour l'étudiant (rôle => description)"
  type = map(object({
    index         = number
    template      = string
    nics          = list(string)
    cores         = optional(number, 2)
    memory        = optional(number, 2048)
    agent         = optional(bool, false)
    bios          = optional(string, "seabios")
    scsi_hardware = optional(string, "virtio-scsi-single")
  }))
}

# --- Réseau -------------------------------------------------------------------

variable "bridge_base" {
  description = "Base de numérotation des bridges (400 → ETU01 = vmbr401…405)"
  type        = number
}

variable "bridges_par_etudiant" {
  description = "Nombre de bridges réservés par étudiant"
  type        = number
}

variable "wan_bridge" {
  description = "Bridge de la carte « wan » (patte out du SNS)"
  type        = string
}

variable "wan_vlan_id" {
  description = "Tag VLAN de la carte « wan », null si aucun"
  type        = number
  default     = null
}
