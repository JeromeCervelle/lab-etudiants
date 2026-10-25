###############################################################################
# main.tf — Point d'entrée : un lab complet par étudiant
###############################################################################
#
# Principe général
# ----------------
# Le Proxmox du lycée contient déjà, pour chaque étudiant :
#   - un pool  SIO2026_<login>  sur lequel son compte a des droits ;
#   - 5 bridges réseau qui lui sont réservés (ETUxx-VLAN01 à ETUxx-VLAN05).
#
# Terraform ne crée NI les comptes, NI les pools, NI les bridges. Il crée
# uniquement les VM de chaque étudiant (par défaut : un firewall Stormshield,
# un serveur Windows et un client Windows), les range dans le pool de
# l'étudiant et les branche sur ses bridges.
#
# Fonctionnement
# --------------
# var.etudiants est une table « login => { etu = numéro } » chargée depuis
# classes/<classe>.tfvars. Les deux blocs ci-dessous utilisent « for_each »
# sur cette table : Terraform les répète donc une fois par étudiant, chaque
# copie étant identifiée par le login (ex. module.lab["dupont.alice"]).
#
# Ajouter une ligne dans la table crée le lab d'un nouvel étudiant ; en
# retirer une supprime ses VM. Les autres étudiants ne sont jamais touchés.
###############################################################################


# -----------------------------------------------------------------------------
# Lecture des pools existants (data source = lecture seule)
# -----------------------------------------------------------------------------
# Pour chaque étudiant, on demande à Proxmox le pool « SIO2026_<login> ».
#
# Intérêt : si un login est mal orthographié dans la liste ou si le pool n'a
# pas été créé, `terraform plan` échoue immédiatement avec le nom du pool
# introuvable, AVANT de créer la moindre VM.
#
# Le pool n'est que lu : un `terraform destroy` ne le supprime pas.
# -----------------------------------------------------------------------------
data "proxmox_virtual_environment_pool" "etudiant" {
  for_each = var.etudiants

  # each.key = le login, ex. "dupont.alice" → pool "SIO2026_dupont.alice"
  pool_id = "${var.pool_prefix}${each.key}"

  lifecycle {
    # Contrôle de cohérence, avant toute création : chaque VM de lab_vms doit
    # utiliser un template déclaré dans var.templates (ex. « mint » ou
    # « kali » oublié dans terraform.tfvars).
    precondition {
      condition     = alltrue([for vm in values(var.lab_vms) : contains(keys(var.templates), vm.template)])
      error_message = "lab_vms utilise un template absent de templates (terraform.tfvars) : ${join(", ", setsubtract([for vm in values(var.lab_vms) : vm.template], keys(var.templates)))}."
    }
  }
}


# -----------------------------------------------------------------------------
# Un lab par étudiant (module réutilisable modules/student_lab)
# -----------------------------------------------------------------------------
# Le module contient toute la logique de création des VM d'UN étudiant.
# On l'appelle ici une fois par étudiant en lui passant :
#   - l'identité de l'étudiant (login, numéro ETU, pool) ;
#   - les paramètres communs à toute la classe (templates, réseau, VM…).
# -----------------------------------------------------------------------------
module "lab" {
  source   = "./modules/student_lab"
  for_each = var.etudiants

  # --- Identité de l'étudiant ------------------------------------------------
  classe = var.classe     # ex. "sio2026", posé en tag sur les VM
  login  = each.key       # ex. "dupont.alice", utilisé dans le nom des VM
  etu    = each.value.etu # ex. 1 pour ETU01 : fixe ses bridges et ses VMID

  # Pool lu ci-dessus : passer par le data source garantit qu'il existe.
  pool_id = data.proxmox_virtual_environment_pool.etudiant[each.key].pool_id

  # --- Où et comment créer les VM -------------------------------------------
  node_name       = var.node_name       # nœud qui porte les bridges étudiants
  templates       = var.templates       # VMID + nœud de chaque template
  linked_clone    = var.linked_clone    # clone lié (true) ou complet (false)
  clone_datastore = var.clone_datastore # stockage cible des clones complets
  lab_vms         = var.lab_vms         # liste des VM à créer par étudiant
  start_vms       = var.start_vms       # démarrer les VM après création ?
  keyboard_layout = var.keyboard_layout # clavier de la console noVNC
  vmid_base       = var.vmid_base       # base du calcul des VMID

  # --- Réseau ----------------------------------------------------------------
  bridge_base          = var.bridge_base          # 400 → ETU01 commence à vmbr401
  bridges_par_etudiant = var.bridges_par_etudiant # 5 bridges par étudiant
  wan_bridge           = var.wan_bridge           # bridge de la patte « out » du SNS
  wan_vlan_id          = var.wan_vlan_id          # tag VLAN éventuel sur le WAN

  # --- Challenge CTF (facultatif) ----------------------------------------------
  ctf        = var.ctf
  ctf_numero = coalesce(each.value.ctf, var.ctf.numero) # CTF propre à l'étudiant, sinon celui de la classe
  ctf_outils = try(terraform_data.ctf_outils[0].id, "")
}


# -----------------------------------------------------------------------------
# Challenge CTF : dépôt de l'installateur sur le nœud (une seule fois)
# -----------------------------------------------------------------------------
# Copie scripts/ctf_installer.sh dans ctf.node_dir sur le nœud, et vérifie
# que ctf_creer.sh y est présent. Recopié automatiquement si le script
# change (empreinte md5). Les installations des étudiants attendent cette
# étape (variable ctf_outils du module).
resource "terraform_data" "ctf_outils" {
  count            = var.ctf.enabled ? 1 : 0
  triggers_replace = [filemd5("${path.module}/scripts/ctf_installer.sh")]

  connection {
    type        = "ssh"
    host        = var.ctf.ssh_host
    user        = var.ctf.ssh_user
    private_key = file(pathexpand(var.ctf.ssh_private_key))
  }

  provisioner "remote-exec" {
    inline = [
      "mkdir -p ${var.ctf.node_dir}",
      "test -f ${var.ctf.node_dir}/ctf_creer.sh || { echo 'ctf_creer.sh absent de ${var.ctf.node_dir} (voir docs/CTF.md)' >&2; exit 1; }",
    ]
  }

  provisioner "file" {
    source      = "${path.module}/scripts/ctf_installer.sh"
    destination = "${var.ctf.node_dir}/ctf_installer.sh"
  }
}
