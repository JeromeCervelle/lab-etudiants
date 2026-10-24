###############################################################################
# modules/student_lab/ctf.tf — Le conteneur CTF de l'étudiant (facultatif)
###############################################################################
#
# Adaptation à Terraform du challenge « 5 CTF pour Proxmox VE » de Damien
# SCONTRINO (licence CC BY-NC-SA 4.0). Le script d'origine crée ses
# conteneurs hors de tout pool, sur un pont commun, avec des adresses
# <préfixe>.1nn. Ici, chaque conteneur CTF :
#   - est créé et supprimé par Terraform, comme les VM du lab ;
#   - est rangé dans le POOL de l'étudiant (il le voit avec ses droits) ;
#   - finit sur un VLAN de l'étudiant (par défaut VLAN01, le LAN du client) ;
#   - est installé par le script d'origine, avec le NUMÉRO ETU de l'étudiant :
#     ses flags sont donc ceux des corrigés du challenge (ETU07 = étudiant 7).
#
# Déroulement pour un étudiant :
#   1. proxmox_virtual_environment_container.ctf : conteneur Debian 12 non
#      privilégié, branché provisoirement sur le réseau d'installation (le
#      WAN par défaut) pour télécharger ses paquets ;
#   2. terraform_data.ctf_install : Terraform se connecte en SSH au nœud et
#      lance scripts/ctf_installer.sh, qui installe le CTF, rapatrie les
#      fiches puis bascule le conteneur sur le VLAN de l'étudiant.
#
# Tout est conditionné par var.ctf.enabled (count = 0 ou 1).
###############################################################################

locals {
  ctf_on   = var.ctf.enabled
  ctf_nn   = format("%02d", var.etu)
  ctf_nom  = "CTF${var.ctf_numero}"
  ctf_vmid = var.vmid_base + var.etu * 10 + var.ctf.index # ETU07, index 9 → 10079

  # Adresse pendant l'installation : "dhcp", ou un modèle "10.187.35.%d/24"
  # complété par install_ip_offset + etu (ETU07, offset 150 → .157).
  ctf_install_ip = var.ctf.install_ip == "dhcp" ? "dhcp" : format(var.ctf.install_ip, var.ctf.install_ip_offset + var.etu)
}

# -----------------------------------------------------------------------------
# Numéro du CTF de l'étudiant
# -----------------------------------------------------------------------------
# Objet témoin : quand le numéro change (ex. l'étudiant passe du CTF1 au
# CTF2), il change, et provoque le remplacement du conteneur (voir
# replace_triggered_by plus bas). C'est l'équivalent, déclenché par
# l'enseignant, de la « progression automatique » du script d'origine.
resource "terraform_data" "ctf_choix" {
  count = local.ctf_on ? 1 : 0
  input = var.ctf_numero
}

# -----------------------------------------------------------------------------
# Le conteneur
# -----------------------------------------------------------------------------
# Mêmes réglages que ctf_creer.sh : Debian 12, non privilégié, nesting,
# 512 Mo, 1 cœur, 8 Go, root sans mot de passe (accès enseignant par
# « pct enter »).
resource "proxmox_virtual_environment_container" "ctf" {
  count = local.ctf_on ? 1 : 0

  node_name   = var.node_name
  vm_id       = local.ctf_vmid
  pool_id     = var.pool_id
  description = "${local.ctf_nom} — ${var.login} (ETU${local.ctf_nn}). Challenge 5 CTF de D. SCONTRINO (CC BY-NC-SA 4.0). Géré par Terraform."
  tags        = [var.classe, format("etu%02d", var.etu), "ctf", lower(local.ctf_nom)]

  unprivileged = true
  features {
    nesting = true # demandé par les CTF (services systemd récents)
  }

  operating_system {
    template_file_id = var.ctf.template # ex. "templates-OCI:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    type             = "debian"
  }

  cpu {
    cores = var.ctf.cores
  }

  memory {
    dedicated = var.ctf.memory
    swap      = 512
  }

  disk {
    datastore_id = var.ctf.datastore
    size         = var.ctf.disk_go
  }

  # Configuration de départ : réseau d'INSTALLATION. Le script d'installation
  # remplace ensuite la carte (VLAN de l'étudiant) : Terraform ignore donc
  # ces attributs après la création (lifecycle plus bas).
  initialization {
    hostname = "${local.ctf_nom}-Etudiant${local.ctf_nn}"

    ip_config {
      ipv4 {
        address = local.ctf_install_ip
        gateway = local.ctf_install_ip == "dhcp" ? null : var.ctf.install_gateway
      }
    }

    dynamic "dns" {
      for_each = var.ctf.install_dns == null ? [] : [var.ctf.install_dns]
      content {
        servers = [dns.value]
      }
    }
  }

  network_interface {
    name     = "eth0"
    bridge   = coalesce(var.ctf.install_bridge, var.wan_bridge)
    firewall = false
  }

  started       = true # il doit tourner pour être installé
  start_on_boot = false

  lifecycle {
    # Le réseau est modifié par ctf_installer.sh, et l'étudiant allume et
    # éteint son conteneur : Terraform ne revient pas dessus.
    ignore_changes = [network_interface, initialization, started]

    # Nouveau numéro de CTF → nouveau conteneur (puis nouvelle installation).
    replace_triggered_by = [terraform_data.ctf_choix]
  }
}

# -----------------------------------------------------------------------------
# L'installation (exécutée une fois, sur le nœud, par SSH)
# -----------------------------------------------------------------------------
# « pct push / pct exec » n'existent pas dans l'API Proxmox : il faut les
# lancer sur le nœud qui porte le conteneur. D'où la connexion SSH.
resource "terraform_data" "ctf_install" {
  count = local.ctf_on ? 1 : 0

  # Ordre : le script ctf_installer.sh doit d'abord être déposé sur le nœud
  # (terraform_data.ctf_outils, à la racine).
  input = var.ctf_outils

  connection {
    type        = "ssh"
    host        = var.ctf.ssh_host
    user        = var.ctf.ssh_user
    private_key = file(pathexpand(var.ctf.ssh_private_key))
  }

  provisioner "remote-exec" {
    inline = [
      join(" ", [
        "bash ${var.ctf.node_dir}/ctf_installer.sh",
        proxmox_virtual_environment_container.ctf[0].vm_id,
        var.ctf_numero,
        var.etu,
        local.bridges[var.ctf.vlan],
        var.ctf.ip,
        coalesce(var.ctf.gateway, "-"),
        coalesce(var.ctf.dns, "-"),
      ])
    ]
  }

  lifecycle {
    # Conteneur recréé (-replace, changement de CTF) → réinstallation.
    replace_triggered_by = [proxmox_virtual_environment_container.ctf]
  }
}
