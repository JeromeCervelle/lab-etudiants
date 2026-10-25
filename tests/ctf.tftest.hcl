###############################################################################
# tests/ctf.tftest.hcl — Tests du challenge CTF, sans toucher à Proxmox
###############################################################################
# Lancement :  terraform test      (Terraform ≥ 1.7, ou OpenTofu ≥ 1.8)
# Le provider Proxmox est simulé (mock_provider) : aucun appel à l'API,
# aucune connexion SSH. On vérifie seulement ce que Terraform calcule
# (VMID, noms, adresses) et les contrôles des variables.
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

    mutillidae = { vm_id = 286, node = "siohyp2" }
  }
  etudiants = {
    "dupont.alice" = { etu = 1 }
    "martin.bilal" = { etu = 7, ctf = 3 }
  }
}

# Sans var.ctf : rien ne change pour le lab existant.
run "sans_ctf" {
  command = plan
  assert {
    condition     = output.labs["dupont.alice"].ctf == null && length(output.labs["dupont.alice"].vms) == 6
    error_message = "Sans ctf.enabled, aucun conteneur CTF ne doit être prévu."
  }
}

run "avec_ctf" {
  command = plan
  variables {
    ctf = { enabled = true, template = "templates-OCI:vztmpl/debian-12.tar.zst", ssh_host = "192.0.2.1" }
  }
  assert {
    condition     = output.labs["dupont.alice"].ctf.vmid == 10019 && output.labs["dupont.alice"].ctf.nom == "CTF1-Etudiant01"
    error_message = "ETU01 : conteneur 10019 « CTF1-Etudiant01 » attendu."
  }
  assert {
    condition     = output.labs["martin.bilal"].ctf.vmid == 10079 && output.labs["martin.bilal"].ctf.nom == "CTF3-Etudiant07"
    error_message = "Le CTF propre à l'étudiant (ctf = 3) doit l'emporter sur celui de la classe."
  }
  assert {
    condition     = output.labs["martin.bilal"].ctf.ip == "192.168.56.50"
    error_message = "Adresse finale 192.168.56.50 attendue."
  }
}

run "ip_installation_statique" {
  command = plan
  variables {
    ctf = { enabled = true, template = "templates-OCI:vztmpl/d.tar.zst", ssh_host = "h", install_ip = "10.187.35.%d/24", install_gateway = "10.187.35.254" }
  }
}

run "ip_statique_sans_passerelle_refusee" {
  command = plan
  variables {
    ctf = { enabled = true, template = "templates-OCI:vztmpl/d.tar.zst", ssh_host = "h", install_ip = "10.187.35.%d/24" }
  }
  expect_failures = [var.ctf]
}

run "modele_obligatoire" {
  command = plan
  variables {
    ctf = { enabled = true, ssh_host = "h" }
  }
  expect_failures = [var.ctf]
}
