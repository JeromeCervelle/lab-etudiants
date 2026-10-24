#!/bin/bash
###############################################################################
# scripts/ctf_installer.sh — Installe un CTF dans le conteneur d'un étudiant
###############################################################################
#
# Exécuté SUR LE NŒUD Proxmox (siohyp2) par Terraform, via SSH (provisioner
# remote-exec de modules/student_lab/ctf.tf), une fois par conteneur créé.
#
# Il reprend, pour UN conteneur, l'étape 4 de ctf_creer.sh (challenge
# « 5 CTF pour Proxmox VE » de Damien SCONTRINO, licence CC BY-NC-SA 4.0) :
#   1. extrait le script d'installation du CTF choisi, embarqué en base64
#      dans ctf_creer.sh (le fichier d'origine n'est PAS modifié ni recopié) ;
#   2. attend que le conteneur ait Internet (il est alors sur le WAN) ;
#   3. pousse le script et l'exécute avec le numéro de l'étudiant, ce qui
#      génère ses flags (les mêmes que dans les corrigés du challenge) ;
#   4. restreint les droits des fichiers de flags ;
#   5. rapatrie les fiches de l'étudiant (flags, identifiants) sur le nœud ;
#   6. bascule le conteneur du WAN vers le VLAN de l'étudiant et le redémarre.
#
# Usage :
#   ctf_installer.sh CTID N_CTF ETU BRIDGE IP/MASQUE PASSERELLE|- DNS|-
#   ex. ctf_installer.sh 10019 1 1 vmbr401 192.168.56.50/24 192.168.56.254 -
#
# Variables d'environnement facultatives :
#   CTF_CREER     chemin de ctf_creer.sh     (défaut : dossier de ce script)
#   CTF_RESULTATS dossier des fiches         (défaut : <dossier>/ctf_resultats)
###############################################################################
set -uo pipefail
export LC_ALL=C.UTF-8

ICI="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CTF_CREER="${CTF_CREER:-$ICI/ctf_creer.sh}"
RESULTATS="${CTF_RESULTATS:-$ICI/ctf_resultats}"
JOURNAL="/var/log/ctf_terraform.log"

if [[ $# -ne 7 ]]; then
    echo "Usage : $0 CTID N_CTF ETU BRIDGE IP/MASQUE PASSERELLE|- DNS|-" >&2
    exit 2
fi
CTID=$1 N=$2 ETU=$3 BRIDGE=$4 IP=$5 GW=$6 DNS=$7
[[ "$GW" == "-" ]] && GW=""
[[ "$DNS" == "-" ]] && DNS=""
NN=$(printf '%02d' "$ETU")

touch "$JOURNAL" && chmod 600 "$JOURNAL"       # le journal contient les flags
log()  { printf '[%s] CT %s ETU%s : %s\n' "$(date '+%F %T')" "$CTID" "$NN" "$*" | tee -a "$JOURNAL"; }
die()  { log "ERREUR : $*"; exit 1; }

# --- 1. Script d'installation du CTF -----------------------------------------
[[ -f "$CTF_CREER" ]] || die "$CTF_CREER introuvable : déposer ctf_creer.sh sur le nœud (voir docs/CTF.md)."
[[ "$N" =~ ^[1-5]$ ]] || die "numéro de CTF invalide : $N (1 à 5)."

# Nom du CTF (« CTF1 »…) et script : lus dans ctf_creer.sh, sans l'exécuter.
NOM=$(awk -F'"' -v n="$N" 'index($0, "CTF_NOM[" n "]=\"") == 1 { print $2; exit }' "$CTF_CREER")
[[ -n "$NOM" ]] || die "CTF_NOM[$N] introuvable dans $CTF_CREER."
TMP=$(mktemp) || die "mktemp impossible."
trap 'rm -f "$TMP"' EXIT
awk -v n="$N" 'index($0, "CTF_B64[" n "]=\047") == 1 { f = 1; next } f && /^\047$/ { f = 0 } f' "$CTF_CREER" \
    | base64 -d > "$TMP" 2>/dev/null
[[ -s "$TMP" ]] || die "script du $NOM illisible dans $CTF_CREER."
log "installation du $NOM (étudiant $ETU)"

# --- 2. Démarrage et accès Internet ------------------------------------------
for _ in {1..30}; do pct exec "$CTID" -- true &>/dev/null && break; sleep 2; done
pct exec "$CTID" -- true &>/dev/null || die "conteneur injoignable par pct exec."
for _ in {1..30}; do
    timeout 5 pct exec "$CTID" -- getent hosts deb.debian.org &>/dev/null && break
    sleep 3
done
timeout 5 pct exec "$CTID" -- getent hosts deb.debian.org &>/dev/null \
    || die "pas d'accès Internet depuis le conteneur sur le réseau d'installation (DHCP, passerelle ou DNS)."

# --- 3. Installation -----------------------------------------------------------
# Le numéro est passé SANS zéro devant (« 08 » serait lu en octal), en
# argument ET sur l'entrée standard : selon le CTF, le script le lit par $1
# ou par read. C'est exactement l'appel de ctf_creer.sh.
pct push "$CTID" "$TMP" /root/script.sh --perms 0700 || die "dépôt du script impossible."
pct exec "$CTID" -- bash /root/script.sh "$ETU" <<< "$ETU" >> "$JOURNAL" 2>&1 \
    || die "le script d'installation du $NOM a échoué (voir $JOURNAL)."
log "installation terminée"

# --- 4. Droits des flags (comme restreindre_droits_flags de ctf_creer.sh) ----
case "$N" in
    1) pct exec "$CTID" -- find /home -mindepth 2 -maxdepth 2 -name flag.txt -exec chmod 600 {} + ;;
    2) pct exec "$CTID" -- chmod 700 /opt/ctf_tracking && pct exec "$CTID" -- chmod 600 /opt/ctf_tracking/flags.csv ;;
esac || log "ATTENTION : droits des flags non restreints, à corriger à la main."

# --- 5. Fiches de l'étudiant ---------------------------------------------------
mkdir -p "$RESULTATS/$NOM" && chmod 700 "$RESULTATS"
fiches=0
for f in /opt/ctf_tracking/flags.csv "/root/infos_tp1_${ETU}.txt"; do
    pct exec "$CTID" -- test -f "$f" 2>/dev/null || continue
    pct pull "$CTID" "$f" "$RESULTATS/$NOM/etudiant${NN}_$(basename "$f")" && fiches=$((fiches + 1))
done
chmod 600 "$RESULTATS/$NOM"/* 2>/dev/null
(( fiches > 0 )) || die "aucune fiche rapatriée dans $RESULTATS/$NOM."
log "$fiches fiche(s) dans $RESULTATS/$NOM"

# --- 6. Bascule sur le VLAN de l'étudiant -----------------------------------
# Le conteneur quitte le WAN : il n'est plus joignable que depuis le réseau
# de l'étudiant (et n'a plus Internet tant que le SNS n'est pas configuré).
pct set "$CTID" --net0 "name=eth0,bridge=${BRIDGE},ip=${IP}${GW:+,gw=$GW},firewall=0" \
    || die "bascule réseau impossible."
if [[ -n "$DNS" ]]; then pct set "$CTID" --nameserver "$DNS"; fi
pct reboot "$CTID" || die "redémarrage impossible."
log "basculé sur $BRIDGE ($IP) : prêt"
