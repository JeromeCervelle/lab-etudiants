variable "classe" { type = string }
variable "login" { type = string }
variable "etu" { type = number }
variable "pool_id" { type = string }

variable "node_name" { type = string }
variable "templates" {
  type = map(object({
    vm_id = number
    node  = string
  }))
}
variable "linked_clone" { type = bool }
variable "clone_datastore" {
  type    = string
  default = null
}
variable "start_vms" { type = bool }
variable "keyboard_layout" { type = string }
variable "vmid_base" { type = number }

variable "lab_vms" {
  type = map(object({
    index    = number
    template = string
    nics     = list(string)
    cores    = optional(number, 2)
    memory   = optional(number, 2048)
    agent    = optional(bool, false)
    bios          = optional(string, "seabios")
    scsi_hardware = optional(string, "virtio-scsi-single")
  }))
}

variable "bridge_base" { type = number }
variable "bridges_par_etudiant" { type = number }
variable "wan_bridge" { type = string }
variable "wan_vlan_id" {
  type    = number
  default = null
}
