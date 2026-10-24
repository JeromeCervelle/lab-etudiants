###############################################################################
# tests/lab.tftest.hcl — Tests du contenu d'un lab, sans toucher à Proxmox
###############################################################################
# Lancement :  terraform test      (Terraform ≥ 1.7, ou OpenTofu ≥ 1.8)
# Le provider Proxmox est simulé : aucun appel à l'API. On vérifie ce que
# Terraform calcule pour chaque étudiant (VMID, rôles, contrôles).
###############################################################################

mock_provider "proxmox" {}

variables {
  proxmox_endpoint  = "https://192.0.2.1:8006/"
  proxmox_api_token = "terraform@pve!tf=test"
  classe            = "sio2026"
  templates = {
    sns    = { vm_id = 404, node = "siohyp2" }
    winsrv = { vm_id = 267, node = "siohyp2" }
    wincli = { vm_id = 270, node = "siohyp2" }
    mint   = { vm_id = 280, node = "siohyp2" }
    kali   = { vm_id = 283, node = "siohyp2" }
  }
  etudiants = {
    "dupont.alice" = { etu = 1 }
    "martin.bilal" = { etu = 38 }
  }
}

# 5 VM par étudiant, VMID 10NN1 à 10NN5, bridges calculés.
run "cinq_vm_par_etudiant" {
  command = plan
  assert {
    condition = output.labs["dupont.alice"].vms == {
      sns = 10011, srv = 10012, cli = 10013, mint = 10014, kali = 10015
    }
    error_message = "ETU01 : VMID 10011 à 10015 attendus (sns, srv, cli, mint, kali)."
  }
  assert {
    condition     = output.labs["martin.bilal"].vms.kali == 10385 && output.labs["martin.bilal"].bridges.vlan01 == "vmbr586"
    error_message = "ETU38 : Kali en 10385, VLAN01 sur vmbr586."
  }
}

# Un template oublié dans terraform.tfvars est signalé clairement.
run "template_manquant" {
  command = plan
  variables {
    templates = {
      sns    = { vm_id = 404, node = "siohyp2" }
      winsrv = { vm_id = 267, node = "siohyp2" }
      wincli = { vm_id = 270, node = "siohyp2" }
    }
  }
  expect_failures = [data.proxmox_virtual_environment_pool.etudiant]
}

# Deux VM ne peuvent pas partager un index (même VMID).
run "index_en_double" {
  command = plan
  variables {
    lab_vms = {
      cli  = { index = 3, template = "wincli", nics = ["vlan01"] }
      mint = { index = 3, template = "mint", nics = ["vlan01"] }
    }
  }
  expect_failures = [var.lab_vms]
}
