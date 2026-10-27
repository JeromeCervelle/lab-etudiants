###############################################################################
# modules/student_lab/main.tf — Les VM d'UN étudiant
###############################################################################
#
# Ce module est appelé une fois par étudiant depuis le main.tf racine.
# Il reçoit l'identité de l'étudiant (login, numéro ETU, pool) et les
# paramètres communs, puis :
#   1. calcule les noms des 5 bridges réservés à l'étudiant ;
#   2. crée chaque VM décrite dans var.lab_vms par clonage d'un template ;
#   3. branche les cartes réseau sur le WAN ou sur les bridges de l'étudiant.
#
# Dans l'état Terraform, une VM est identifiée par son adresse complète, ex. :
#   module.lab["dupont.alice"].proxmox_virtual_environment_vm.vm["sns"]
# C'est cette adresse qu'on passe à -replace ou -target pour agir sur une
# seule VM.
###############################################################################

# Un module doit déclarer les providers qu'il utilise. La version est fixée
# une seule fois, à la racine (versions.tf).
terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
    }
  }
}


# -----------------------------------------------------------------------------
# Calcul des bridges de l'étudiant
# -----------------------------------------------------------------------------
# « locals » = valeurs intermédiaires calculées une fois et réutilisées.
#
# Exemple pour ETU02 (bridge_base = 400, bridges_par_etudiant = 5) :
#   first   = 400 + (2 - 1) × 5 = 405
#   bridges = { vlan01 = "vmbr406", vlan02 = "vmbr407", vlan03 = "vmbr408",
#               vlan04 = "vmbr409", vlan05 = "vmbr410" }
# -----------------------------------------------------------------------------
locals {
  # Numéro du bridge qui PRÉCÈDE le premier bridge de l'étudiant.
  first = var.bridge_base + (var.etu - 1) * var.bridges_par_etudiant

  # Table « vlanNN » => « vmbrXXX ». format("vlan%02d", 1) donne "vlan01".
  bridges = {
    for n in range(1, var.bridges_par_etudiant + 1) :
    format("vlan%02d", n) => "vmbr${local.first + n}"
  }
}


# -----------------------------------------------------------------------------
# Les VM de l'étudiant
# -----------------------------------------------------------------------------
# for_each sur var.lab_vms : un exemplaire de cette ressource par VM du lab
# (sns, srv, cli…). each.key = le rôle ("sns"), each.value = sa description.
# -----------------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "vm" {
  for_each = var.lab_vms

  # --- Identification ---------------------------------------------------------
  # Nom visible dans Proxmox : "<login>-<rôle>", ex. "dupont.alice-sns".
  name = "${var.login}-${each.key}"

  description = "Lab ${var.classe} — ${var.login} (ETU${format("%02d", var.etu)}). Géré par Terraform."

  # Nœud où la VM est créée : celui qui porte les bridges étudiants.
  node_name = var.node_name

  # VMID déterministe : vmid_base + etu × 10 + index → ETU07 sns = 10071.
  # Un VMID fixe permet de retrouver une VM sans consulter Terraform.
  vm_id = var.vmid_base + var.etu * 10 + each.value.index

  # Rangement dans le pool de l'étudiant : il voit et pilote ses VM avec les
  # droits déjà attribués à son compte sur ce pool.
  pool_id = var.pool_id

  # Tags Proxmox, pratiques pour filtrer dans l'interface web :
  # "sio2026", "etu07", "sns".
  tags = [var.classe, format("etu%02d", var.etu), each.key]

  # --- Matériel repris du template ---------------------------------------------
  # Le provider bpg applique ses valeurs par défaut au clone (seabios,
  # virtio-scsi-pci, clavier en-us) au lieu de garder celles du template.
  # On les fixe donc explicitement pour qu'elles correspondent au template.
  bios            = each.value.bios          # "ovmf" pour les Windows UEFI
  scsi_hardware   = each.value.scsi_hardware # "virtio-scsi-single"
  keyboard_layout = var.keyboard_layout      # "fr" pour la console noVNC

  # Le type de machine (q35), le disque EFI et le TPM 2.0 ne sont pas déclarés
  # ici : Terraform ne les gère pas et ils sont copiés tels quels du template.

  # --- Clonage ---------------------------------------------------------------
  clone {
    # Template à cloner, choisi par la clé « template » de la VM.
    vm_id = var.templates[each.value.template].vm_id

    # Nœud qui porte le template : il peut être différent de node_name (cas
    # du SNS 404 sur siohyp1). Proxmox réalise alors le clone vers node_name,
    # ce qui suppose un stockage partagé.
    node_name = var.templates[each.value.template].node

    # full = false → clone lié ; full = true → clone complet.
    full = !var.linked_clone

    # Stockage cible : seulement pour un clone complet. Un clone lié reste
    # obligatoirement sur le stockage du template.
    datastore_id = var.linked_clone ? null : var.clone_datastore
  }

  # --- Ressources ------------------------------------------------------------
  cpu {
    cores = each.value.cores

    # "host" expose au système invité le vrai processeur du nœud : meilleures
    # performances, et jeu d'instructions complet pour Windows 11 / Server
    # 2025. Contrepartie : la migration à chaud entre nœuds de CPU
    # différents peut échouer (sans importance ici).
    type = "host"
  }

  memory {
    dedicated = each.value.memory # en Mo
  }

  # QEMU Guest Agent : s'il est activé, Terraform attend que l'agent remonte
  # les adresses IP de la VM. À n'activer que si l'agent est installé dans le
  # template, sinon le plan reste bloqué jusqu'au délai d'expiration.
  agent {
    enabled = each.value.agent
  }

  # --- Cartes réseau -----------------------------------------------------------
  # « dynamic » génère un bloc network_device par élément de nics, dans
  # l'ordre. Ces cartes REMPLACENT celles du template.
  #   "wan"    → bridge WAN commun (vmbr134), avec un tag VLAN éventuel ;
  #   "vlanNN" → bridge correspondant de l'étudiant, sans tag (le VLAN est
  #              porté par le bridge lui-même).
  # Pour le SNS, la 1re carte devient l'interface out, la 2e in, la 3e dmz1,
  # la 4e dmz2, la 5e dmz3, la 6e dmz4.
  dynamic "network_device" {
    for_each = each.value.nics
    content {
      model    = "virtio" # pilote paravirtualisé, le plus performant
      bridge   = network_device.value == "wan" ? var.wan_bridge : local.bridges[network_device.value]
      vlan_id  = network_device.value == "wan" ? var.wan_vlan_id : null
      firewall = false # le filtrage est le travail du SNS, pas de Proxmox
    }
  }

  # --- Cycle de vie ------------------------------------------------------------
  started = var.start_vms # démarrer ou non après la création
  on_boot = false         # ne pas démarrer au redémarrage du nœud

  # Lors d'un destroy ou d'un replace, arrêter la VM de force avant de la
  # supprimer (sinon la suppression d'une VM allumée échoue).
  stop_on_destroy = true

  lifecycle {
    # Les étudiants allument et éteignent leurs VM : sans cette ligne, chaque
    # `plan` proposerait de remettre la VM dans l'état « started » initial.
    ignore_changes = [started]
  }
}
