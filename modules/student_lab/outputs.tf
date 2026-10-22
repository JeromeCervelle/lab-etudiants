output "bridges" {
  value = local.bridges
}

output "vm_ids" {
  value = { for k, vm in proxmox_virtual_environment_vm.vm : k => vm.vm_id }
}
