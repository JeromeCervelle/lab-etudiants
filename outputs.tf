output "labs" {
  description = "Pour chaque étudiant : numéro ETU, pool, bridges et VMIDs"
  value = {
    for login, lab in module.lab : login => {
      etu     = format("ETU%02d", var.etudiants[login].etu)
      pool    = data.proxmox_virtual_environment_pool.etudiant[login].pool_id
      bridges = lab.bridges
      vms     = lab.vm_ids
    }
  }
}
