###############################################################################
# modules/student_lab/outputs.tf — Sorties du module
###############################################################################
#
# Valeurs renvoyées au main.tf racine, qui les regroupe dans l'output « labs ».
###############################################################################

# Bridges de l'étudiant, ex. { vlan01 = "vmbr401", …, vlan05 = "vmbr405" }.
# Utile pour vérifier qu'un étudiant est branché sur les bons VLAN.
output "bridges" {
  description = "Table vlanNN => bridge réservé à l'étudiant"
  value       = local.bridges
}

# VMID réellement créés, ex. { sns = 10011, srv = 10012, cli = 10013 }.
output "vm_ids" {
  description = "Table rôle => VMID des VM de l'étudiant"
  value       = { for k, vm in proxmox_virtual_environment_vm.vm : k => vm.vm_id }
}

# Conteneur CTF, ex. { vmid = 10019, nom = "CTF1-Etudiant01", ip = "192.168.56.50" },
# ou null si le challenge n'est pas activé.
output "ctf" {
  description = "Conteneur CTF de l'étudiant (null si désactivé)"
  value = local.ctf_on ? {
    vmid = local.ctf_vmid
    nom  = "${local.ctf_nom}-Etudiant${local.ctf_nn}"
    ip   = split("/", var.ctf.ip)[0]
  } : null
}
