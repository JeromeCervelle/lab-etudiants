#!/usr/bin/env bash
# Génère la liste "etudiants" à partir des pools existants, puis vérifie
# que chaque étudiant a bien ses bridges sur le nœud cible.
# À lancer sur un nœud Proxmox (root). Aucune dépendance : perl et
# libjson-perl sont fournis avec Proxmox (pas besoin de jq).
#
#   bash genere-etudiants.sh SIO2026_ siohyp2 > ../classes/sio2026-etudiants.txt
#
# Pour écarter des étudiants dont le pool existe encore (logins séparés par des espaces) :
#   EXCLURE="nom.prenom autre.login" bash genere-etudiants.sh SIO2026_ siohyp2
#
# Les numéros ETU sont attribués dans l'ordre alphabétique des pools.
# Les lignes "!!" signalent un bridge absent ou un commentaire ETUxx qui ne
# correspond pas : à corriger AVANT le premier terraform apply.
set -euo pipefail

PREFIX="${1:-SIO2026_}"
NODE="${2:-siohyp2}"
BASE="${BRIDGE_BASE:-400}"           # = bridge_base dans terraform.tfvars
PER="${BRIDGES_PAR_ETUDIANT:-5}"     # = bridges_par_etudiant
EXCLURE="${EXCLURE-}"               # logins à ignorer, séparés par des espaces

# Logins = noms des pools sans le préfixe, triés
mapfile -t LOGINS < <(
  pvesh get /pools --output-format json |
  P="$PREFIX" X="$EXCLURE" perl -MJSON::PP -0777 -ne '
    my %x = map { $_ => 1 } split " ", $ENV{X};
    print "$_\n" for sort
      grep { !$x{$_} }
      map  { substr($_->{poolid}, length $ENV{P}) }
      grep { index($_->{poolid}, $ENV{P}) == 0 } @{ decode_json($_) };'
)

if [ "${#LOGINS[@]}" -eq 0 ]; then
  echo "Aucun pool commençant par $PREFIX" >&2
  exit 1
fi

# Bridges du nœud : iface -> commentaire
declare -A COMMENT
while IFS=$'\t' read -r iface c; do
  COMMENT["$iface"]="$c"
done < <(
  pvesh get "/nodes/$NODE/network" --type bridge --output-format json |
  perl -MJSON::PP -0777 -ne '
    for (@{ decode_json($_) }) {
      (my $c = $_->{comments} // "") =~ s/\s+$//;
      print "$_->{iface}\t$c\n";
    }'
)

echo "etudiants = {"
i=0
for login in "${LOGINS[@]}"; do
  i=$((i + 1))
  printf '  %-24s = { etu = %d }\n' "\"$login\"" "$i"
done
echo "}"

# Contrôle des bridges
echo
echo "# Contrôle sur $NODE (${#LOGINS[@]} étudiants, $PER bridges chacun)"
errors=0
i=0
for login in "${LOGINS[@]}"; do
  i=$((i + 1))
  etu=$(printf 'ETU%02d' "$i")
  first=$((BASE + (i - 1) * PER + 1))
  last=$((BASE + i * PER))
  status="ok"
  for b in $(seq "$first" "$last"); do
    br="vmbr$b"
    if [ -z "${COMMENT[$br]+x}" ]; then
      status="!! $br absent"; errors=$((errors + 1)); break
    fi
    case "${COMMENT[$br]}" in
      "$etu"*) ;;
      *) status="!! $br commenté '${COMMENT[$br]}', attendu $etu"; errors=$((errors + 1)); break ;;
    esac
  done
  printf '#   %s  %-24s vmbr%d..vmbr%d  %s\n' "$etu" "$login" "$first" "$last" "$status"
done

echo "#"
if [ "$errors" -eq 0 ]; then
  echo "# Tout est cohérent."
else
  echo "# $errors étudiant(s) en anomalie : ne pas lancer apply avant correction."
  exit 2
fi
