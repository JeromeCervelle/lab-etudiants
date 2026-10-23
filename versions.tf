###############################################################################
# versions.tf — Version de Terraform, provider Proxmox et connexion à l'API
###############################################################################
#
# Ce fichier dit à Terraform :
#   1. quelle version minimale de Terraform est nécessaire ;
#   2. quel « provider » (plugin) utiliser pour piloter Proxmox ;
#   3. comment se connecter à l'API du cluster Proxmox.
#
# Le provider est téléchargé automatiquement depuis le registre Terraform
# au premier `terraform init`. Sa version exacte est alors figée dans le
# fichier .terraform.lock.hcl, qu'il faut versionner dans Git pour que tous
# les postes utilisent la même version.
###############################################################################

terraform {
  # Terraform 1.6 minimum : nécessaire pour les attributs optional(…, défaut)
  # utilisés dans les variables objet (voir variables.tf).
  required_version = ">= 1.6"

  required_providers {
    proxmox = {
      # Provider communautaire « bpg/proxmox » : le plus complet et le plus
      # maintenu pour Proxmox VE 8. Documentation :
      #   https://registry.terraform.io/providers/bpg/proxmox/latest/docs
      source = "bpg/proxmox"

      # « ~> 0.66 » accepte 0.66, 0.67, 0.68… mais pas 1.0 : on profite des
      # correctifs sans risquer un changement majeur incompatible.
      version = "~> 0.66"
    }
  }
}

# -----------------------------------------------------------------------------
# Connexion à l'API Proxmox
# -----------------------------------------------------------------------------
# Les deux valeurs viennent de terraform.tfvars (fichier NON versionné) :
#
#   proxmox_endpoint  : adresse INTERNE d'un nœud, port 8006.
#                       ⚠ Ne pas utiliser l'adresse publique
#                       siohyp2.educ-valadon-limoges.fr : elle passe par le
#                       proxy Microsoft Entra qui exige une connexion dans un
#                       navigateur, ce que Terraform ne sait pas faire.
#
#   proxmox_api_token : token API de l'utilisateur terraform@pve, sous la
#                       forme « terraform@pve!tf=<secret> ». Créé avec :
#                         pveum user add terraform@pve
#                         pveum aclmod / -user terraform@pve -role Administrator
#                         pveum user token add terraform@pve tf --privsep 0
#
# N'importe quel nœud du cluster convient comme point d'entrée : l'API
# Proxmox relaie les demandes vers le nœud concerné.
# -----------------------------------------------------------------------------
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token

  # Proxmox utilise par défaut un certificat auto-signé. Sans cette option,
  # Terraform refuserait la connexion HTTPS. Acceptable sur le réseau
  # d'administration interne du lycée.
  insecure = true
}
