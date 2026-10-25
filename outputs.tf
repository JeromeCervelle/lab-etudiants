###############################################################################
# outputs.tf — Informations affichées après un apply
###############################################################################
#
# Les « outputs » sont des valeurs que Terraform affiche à la fin d'un
# `apply`, et que l'on peut relire à tout moment sans rien modifier :
#
#   terraform output labs                       # tous les étudiants
#   terraform output -json labs | jq '."dupont.alice"'   # un seul étudiant
#
# Utile pour répondre vite à « quelles sont les VM de tel étudiant ? » ou
# « sur quels bridges est-il branché ? ».
###############################################################################

output "labs" {
  description = "Pour chaque étudiant : numéro ETU, pool, bridges et VMID de ses VM"

  # Une entrée par étudiant, construite à partir des sorties du module. Exemple :
  #   "dupont.alice" = {
  #     etu     = "ETU01"
  #     pool    = "SIO2026_dupont.alice"
  #     bridges = { vlan01 = "vmbr401", vlan02 = "vmbr402", … }
  #     vms     = { sns = 10011, srv = 10012, cli = 10013 }
  #   }
  value = {
    for login, lab in module.lab : login => {
      etu     = format("ETU%02d", var.etudiants[login].etu) # 1 → "ETU01"
      pool    = data.proxmox_virtual_environment_pool.etudiant[login].pool_id
      bridges = lab.bridges # calculés dans le module
      vms     = lab.vm_ids  # VMID réellement attribués par Proxmox
      ctf     = lab.ctf     # conteneur CTF { vmid, nom, ip }, ou null
    }
  }
}
