# Les pools SIO2026_<login> existent déjà (avec les droits des étudiants).
# Ce data source fait échouer le plan tout de suite si un pool est introuvable.
data "proxmox_virtual_environment_pool" "etudiant" {
  for_each = var.etudiants
  pool_id  = "${var.pool_prefix}${each.key}"
}

module "lab" {
  source   = "./modules/student_lab"
  for_each = var.etudiants

  classe  = var.classe
  login   = each.key
  etu     = each.value.etu
  pool_id = data.proxmox_virtual_environment_pool.etudiant[each.key].pool_id

  node_name    = var.node_name
  templates    = var.templates
  linked_clone    = var.linked_clone
  clone_datastore = var.clone_datastore
  lab_vms         = var.lab_vms
  start_vms    = var.start_vms
  vmid_base    = var.vmid_base

  bridge_base          = var.bridge_base
  bridges_par_etudiant = var.bridges_par_etudiant
  wan_bridge           = var.wan_bridge
  wan_vlan_id          = var.wan_vlan_id
}
