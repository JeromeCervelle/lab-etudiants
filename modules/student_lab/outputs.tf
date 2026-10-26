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

# Conteneur CTF RÉELLEMENT créé, ex.
#   { vmid = 10019, nom = "CTF1-Etudiant01", ip = "192.168.56.50" }
# ou null si l'étudiant n'en a pas.
#
# Les valeurs sont lues sur la ressource (son état), et non recalculées à
# partir de la configuration : après un apply limité à quelques étudiants
# (-target), seuls ceux dont le conteneur existe apparaissent. try() renvoie
# null quand la ressource n'a pas d'instance (challenge désactivé, ou
# étudiant pas encore déployé).
output "ctf" {
  description = "Conteneur CTF réellement créé pour l'étudiant (null sinon)"
  value = try({
    vmid = proxmox_virtual_environment_container.ctf[0].vm_id
    nom  = proxmox_virtual_environment_container.ctf[0].initialization[0].hostname
    ip   = split("/", var.ctf.ip)[0]
  }, null)
}
