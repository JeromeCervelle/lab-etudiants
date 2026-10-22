terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}

locals {
  # Bridges de l'étudiant : ETU02 => { vlan01 = "vmbr406", ..., vlan05 = "vmbr410" }
  first = var.bridge_base + (var.etu - 1) * var.bridges_par_etudiant
  bridges = {
    for n in range(1, var.bridges_par_etudiant + 1) :
    format("vlan%02d", n) => "vmbr${local.first + n}"
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.lab_vms

  name        = "${var.login}-${each.key}"
  description = "Lab ${var.classe} — ${var.login} (ETU${format("%02d", var.etu)}). Géré par Terraform."
  node_name   = var.node_name
  vm_id       = var.vmid_base + var.etu * 10 + each.value.index
  pool_id     = var.pool_id
  tags        = [var.classe, format("etu%02d", var.etu), each.key]

  # Le template peut être sur un autre nœud du cluster que la VM créée.
  clone {
    vm_id        = var.templates[each.value.template].vm_id
    node_name    = var.templates[each.value.template].node
    full         = !var.linked_clone
    datastore_id = var.linked_clone ? null : var.clone_datastore
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  # À activer seulement si le template a le QEMU guest agent,
  # sinon Terraform attend une IP qui ne vient jamais.
  agent {
    enabled = each.value.agent
  }

  # Les cartes remplacent celles du template, dans l'ordre de "nics".
  # Bridges non VLAN-aware : le VLAN est porté par le bridge, pas de tag.
  dynamic "network_device" {
    for_each = each.value.nics
    content {
      model    = "virtio"
      bridge   = network_device.value == "wan" ? var.wan_bridge : local.bridges[network_device.value]
      vlan_id  = network_device.value == "wan" ? var.wan_vlan_id : null
      firewall = false
    }
  }

  started         = var.start_vms
  on_boot         = false
  stop_on_destroy = true

  lifecycle {
    # Les étudiants allument/éteignent leurs VMs : on ne revient pas dessus.
    ignore_changes = [started]
  }
}
