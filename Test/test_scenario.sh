#!/bin/bash

set -m
set -euo pipefail  #S'assure de la robustesse du script

PGID=$(ps -o pgid= $$ | grep -o '[0-9]*')

# Variable pour éviter les appels multiples à cleanup
CLEANUP_DONE=0

# Définir un trap pour capturer les signaux et effectuer le nettoyage
trap cleanup EXIT SIGINT SIGTERM


# Vérification des arguments
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 simu|real"
    exit 1
fi

# Initialisation de la variable
MODE_TEST=""

# Gestion des arguments
case $1 in
    simu)
        MODE_TEST="simu"
        ;;
    real)
        MODE_TEST="real"
        ;;
    *)
        echo "Invalid argument. Use 'simu' or 'real'."
        exit 1
        ;;
esac

# Détermine le chemin absolu du répertoire du script
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# Dossiers de traitement temporaire
TMP_DIR=$(mktemp -d)

# Récupérer les variables d'environnement
source "$SCRIPT_DIR/config_test_$MODE_TEST.env"

# Mode de sortie (terminal ou fichier)
OUTPUT_MODE="file"  # Options: terminal, file

CHECKSUM_FILE_REMOTE_PREVIOUS="$TMP_DIR/checksums_remote_previous.txt"
CHECKSUM_FILE_REMOTE_CURRENT="$TMP_DIR/checksums_remote_current.txt"
CHECKSUM_FILE_LOCAL_CURRENT="$TMP_DIR/checksums_local_current.txt"

FILES_TO_SYNC="$TMP_DIR/cloud_files.txt"

LOCK_FILE="$TMP_DIR/sync.lock"
PATCH_DIR="$TMP_DIR/patches"

LOG_FILE="$SCRIPT_DIR/sync.log"

# PID du processus `inotifywait`
INOTIFY_PID_FILE="$TMP_DIR/inotify.pid"
INOTIFY_LOOP_FILE="$TMP_DIR/inotify.loop"

source "$SCRIPT_DIR/../functions.sh"

##############################################################################
#  Scénario Numéro 1 - Test du download
#
# 1) t1 : État initial (local & remote = file1, file2, file3 identiques)
# 2) t2 : Modifications remote (pas de synchro)
# 3) t3 : Modifications local (pas de synchro)
# 4) t4 : Merge en local (géré par VOTRE OUTIL) + synchro local -> remote
# 5) t5 : Synchro remote -> local
#
# But : vérifier qu'au final, file1.txt contient un merge "_<<<< / _>>>>",
#       et que les autres fichiers sont cohérents selon votre logique.
##############################################################################



##############################################################################
# Contenu attendu du MERGE final pour file1.txt
##############################################################################
# Selon votre description, on veut une fusion de ce style :
#   Ligne 1 commun
#   _<<<<<<<<<<<<<
#   Ligne 2 text 1
#   _>>>>>>>>>>>>>
#   Ligne 2 text 2
#   Ligne 2,5 text 2
#
#   Ligne 3 commun
#   _<<<<<<<<<<<<<
#   Ligne 4 text 1
#   _>>>>>>>>>>>>>
#   Ligne 4 text 2
#
# Note : en Bash, attention aux sauts de ligne
MERGED_CONTENT_FILE1="$(cat <<'EOF'
Ligne 1 commun
_<<<<<<<<<<<<<
Ligne 2 text 1
_>>>>>>>>>>>>>
Ligne 2 text 2
Ligne 2,5 text 2

Ligne 3 commun
_<<<<<<<<<<<<<
Ligne 4 text 1
_>>>>>>>>>>>>>
Ligne 4 text 2
EOF
)"

##############################################################################
# Début du scénario de test - T1
##############################################################################

echo "=== Nettoyage et setup initial (t1) ==="
rm -f $CHECKSUM_FILE_LOCAL_CURRENT $CHECKSUM_FILE_REMOTE_PREVIOUS $CHECKSUM_FILE_REMOTE_CURRENT $FILES_TO_SYNC
rm -rf "$LOCK_FILE"

if [ "$MODE_TEST" = "real" ]; then
    rclone delete "$REMOTE_DIR"
fi
mkdir -p "$LOCAL_DIR" "$REMOTE_DIR"

# t1: création initiale de file1, file2, file3
echo "fichier1 initial local" > "$LOCAL_DIR/file1.txt"
echo "fichier2 initial local" > "$LOCAL_DIR/file2.txt"
echo "fichier3 initial local" > "$LOCAL_DIR/file3.txt"

# Copie initiale vers remote
if [ "$MODE_TEST" = "real" ]; then
    sync_remote
    sleep $SYNC_DELAY
else
    cp "$LOCAL_DIR"/* "$REMOTE_DIR"
fi

# Vérif que local et remote sont identiques
assert_file_exists "$LOCAL_DIR/file1.txt"
assert_file_exists "$LOCAL_DIR/file2.txt"
assert_file_exists "$LOCAL_DIR/file3.txt"
assert_file_exists "$REMOTE_DIR/file1.txt"
assert_file_exists "$REMOTE_DIR/file2.txt"
assert_file_exists "$REMOTE_DIR/file3.txt"

echo "[INFO] Étape t1 OK : local & remote identiques"
echo "--------------------------------------"

if [ ! -f "$CHECKSUM_FILE_REMOTE_PREVIOUS" ]; then
    generate_checksums_remote_current
    cp "$CHECKSUM_FILE_REMOTE_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"
fi
generate_checksums_local


##############################################################################
# t2 : Modifications côté REMOTE, pas de synchro
##############################################################################
echo "=== Étape t2 : Modifications sur le remote (PAS de synchro) ==="

# On modifie file1.txt côté remote pour créer un conflit plus tard
rclone rcat "$REMOTE_DIR/file1.txt" <<EOF
Ligne 1 commun
Ligne 2 text 2
Ligne 2,5 text 2
Ligne 3 commun
Ligne 4 text 2
EOF

# On supprime ou modifie file2, file3 côté remote si on veut
# Supposons qu'on supprime file3 et file2 côté remote (sans synchro)
rclone deletefile "$REMOTE_DIR/file2.txt"
rclone deletefile "$REMOTE_DIR/file3.txt"

# Copie initiale vers remote
echo "fichier4 created remote" | rclone rcat "$REMOTE_DIR/file4.txt"

# => Nouveau fichier en remote
assert_file_exists "$REMOTE_DIR/file4.txt"

# => Aucune synchro, local ne change pas
assert_file_exists "$LOCAL_DIR/file2.txt"  # toujours là localement
assert_file_exists "$LOCAL_DIR/file3.txt"  # contenu local inchangé

echo "[INFO] Étape t2 OK : Remote et Local divergent, pas de synchro."
echo "--------------------------------------"




##############################################################################
# t3 : Modifications côté LOCAL, pas de synchro
##############################################################################
echo "=== Étape t3 : Modifications sur le local (PAS de synchro) ==="

# On re-modifie file1.txt côté local pour accentuer le conflit
# (ajoutons un saut de ligne après "Ligne 2 text 1" pour respecter l’exemple initial)
cat > "$LOCAL_DIR/file1.txt" <<EOF
Ligne 1 commun
Ligne 2 text 1
Ligne 3 commun
Ligne 4 text 1
EOF

# On modifie file3 localement aussi, pour tester
echo "Local a changé le contenu de file3" > "$LOCAL_DIR/file3.txt"

# On crée un nouveau file5 localement
echo "fichier5 created local" > "$LOCAL_DIR/file5.txt"

# => Aucune synchro, remote ne change pas
assert_file_not_exists "$REMOTE_DIR/file5.txt"

echo "[INFO] Étape t3 OK : Local et Remote divergent encore plus."
echo "--------------------------------------"




##############################################################################
# t4 : Merge en local (via VOTRE outillage), puis synchro local->remote
#      C'est ici que votre outil doit produire le fichier final merged
#      avec les marqueurs <<<< / >>>>.
##############################################################################
echo "=== Étape t4 : Merge local et copie vers remote ==="

# On suppose que votre outil de synchro est capable de détecter
# les changements sur file1.txt côté local & remote, et de produire
# un contenu final de type "merge conflict" si le code est paramétré ainsi.

echo "[INFO] -> Lancement de la synchro LOCAL -> REMOTE avec merge..."

generate_checksums_local
generate_checksums_remote_current
echo "[INFO] -> Checksums local et remote calculés"
merge_local || true
# Vérif côté LOCAL après le merge vers local
assert_file_exists "$LOCAL_DIR/file1.txt"
assert_file_content "$LOCAL_DIR/file1.txt" "$MERGED_CONTENT_FILE1"
assert_file_exists "$LOCAL_DIR/file2.txt"
assert_file_exists "$LOCAL_DIR/file3.txt"
assert_file_content "$LOCAL_DIR/file3.txt" "Local a changé le contenu de file3"
assert_file_exists "$LOCAL_DIR/file5.txt"


merge_remote
# Vérif côté REMOTE après le merge vers remote
# On s'attend à ce que file1.txt contienne le MERGED_CONTENT_FILE1
# (Votre outil aura ajouté les marqueurs de conflit)
assert_file_exists "$REMOTE_DIR/file1.txt"
assert_file_content "$REMOTE_DIR/file1.txt" "$MERGED_CONTENT_FILE1"

# On s'attend à ce que file3.txt ait été créé sur remote (puisque local l'avait créé) 
# malgré qu'il est été supprimé en remote
assert_file_exists "$REMOTE_DIR/file3.txt"
assert_file_content "$REMOTE_DIR/file3.txt" "Local a changé le contenu de file3"

assert_file_exists "$REMOTE_DIR/file4.txt"

# On s'attend à ce que file5.txt ait été créé sur remote (puisque local l'avait créé)
assert_file_exists "$REMOTE_DIR/file5.txt"

# On vérifie l'état de file2, file3 :
# - file2 local a changé, remote a changé => votre outil doit décider du contenu final.
#   (On n’a pas d’exemple d’un “merge conflict” textuel pour file2, mais vous pouvez en créer un.)
# - file3 a été supprimé sur remote, mais localement encore présent => votre outil
#   doit décider de le supprimer en remote, ou de le conserver, etc.  
#   Ici, on ne force rien à la main.

echo "[INFO] Étape t4 : Merge local->remote effectué."
echo "--------------------------------------"

##############################################################################
# t5 : Synchronisation de remote vers local
#      => vérifier que file1.txt local matche bien le contenu final merged
#         et que tous les autres fichiers sont dans l'état voulu.
##############################################################################
echo "=== Étape t5 : Synchronisation Remote -> Local ==="

sync_local

# Vérif final côté LOCAL : file1.txt doit avoir le contenu MERGED
assert_file_exists "$LOCAL_DIR/file1.txt"
assert_file_content "$LOCAL_DIR/file1.txt" "$MERGED_CONTENT_FILE1"

# Vérifiez ici l'état final des autres fichiers selon votre logique :
# - file2 : contenu final ? (vous pouvez faire un assert_file_content)
# - file3 : existe ? supprimé ? (selon la logique de merge que vous voulez)
# - file5 : créé localement, logiquement présent local & remote

assert_file_not_exists "$LOCAL_DIR/file2.txt"
assert_file_exists "$LOCAL_DIR/file3.txt"
assert_file_content "$LOCAL_DIR/file3.txt" "Local a changé le contenu de file3"
assert_file_exists "$LOCAL_DIR/file4.txt"
assert_file_exists "$LOCAL_DIR/file5.txt"


echo "[INFO] Étape t5 : Final check OK (si pas d'erreur ci-dessus)."
echo "--------------------------------------"

echo "[SUCCESS] Tous les tests du scénario 1 sont passés avec succès !"
echo 
echo

rm -rf "$TMP_DIR"

##############################################################################
#  Scénario Numéro 2 - Test de l'upload
#
# ############################################################################

######################################
# Préparation de l'environnement
######################################
echo "=== Setup initial ==="
rm -rf "$TMP_DIR"
if [ "$MODE_TEST" = "real" ]; then
    rclone delete "$REMOTE_DIR"
fi
mkdir -p "$LOCAL_DIR" "$REMOTE_DIR"

# Création des fichiers initiaux en local
echo "Hello World" > "$LOCAL_DIR/fileA.txt"
echo "Initial content B" > "$LOCAL_DIR/fileB.txt"

# Copie initiale vers remote
if [ "$MODE_TEST" = "real" ]; then
    sync_remote
    sleep $SYNC_DELAY
else
    cp "$LOCAL_DIR"/* "$REMOTE_DIR"
fi

# Vérifications initiales
assert_file_exists "$REMOTE_DIR/fileA.txt"
assert_file_exists "$REMOTE_DIR/fileB.txt"
assert_file_content "$REMOTE_DIR/fileA.txt" "Hello World"
assert_file_content "$REMOTE_DIR/fileB.txt" "Initial content B"

echo "[INFO] État initial identique local / remote OK."
echo "--------------------------------------"

######################################
# Étape 2 : Modification locale simple
#  - fileA.txt modifié en local
#  - on_change() détecte la modif
#  - sync_remote() pousse vers remote
######################################
echo "=== Étape 2 : Modification locale de fileA.txt ==="

trigger_changes_local &

sleep 1

# On simule la modification locale
echo "Hello World + Local edit 1" > "$LOCAL_DIR/fileA.txt"

sleep 5

# Vérifications
assert_file_content "$REMOTE_DIR/fileA.txt" "Hello World + Local edit 1"
echo "[INFO] Étape 2 validée : la modif locale de fileA.txt est répercutée sur remote."
echo "--------------------------------------"

######################################
# Étape 3 : Conflit sur fileB.txt
#  - fileB.txt modifié en local
#  - fileB.txt modifié en remote
#  - on_change() détecte la modif locale + check remote
#  - handle_conflicts() se déclenche
######################################
echo "=== Étape 3 : Conflit sur fileB.txt ==="

trigger_changes_local &

# 3.1 Simultanément, on modifie le fileB côté remote
echo "Remote version B" | rclone rcat "$REMOTE_DIR/fileB.txt"

sleep 1

# 3.2 Modif locale sur fileB
echo "Local version B" > "$LOCAL_DIR/fileB.txt"

sleep 10

MERGED_CONTENT="$(cat <<'EOF'
_<<<<<<<<<<<<<
Local version B
_>>>>>>>>>>>>>
Remote version B

EOF
)"

# Vérification du merge
assert_file_content "$LOCAL_DIR/fileB.txt" "$MERGED_CONTENT"
assert_file_content "$REMOTE_DIR/fileB.txt" "$MERGED_CONTENT"

echo "[INFO] Étape 3 validée : le conflit sur fileB.txt a été détecté et résolu."

##############################################################################
# Fin du script
##############################################################################
echo "[SUCCESS] Tous les tests du scénario 2 sont passés avec succès !"
echo "--------------------------------------"
echo

rm -rf "$TMP_DIR"
if [ "$MODE_TEST" = "real" ]; then
    rclone delete "$REMOTE_DIR"
fi
rm -rf "$LOCK_FILE"


##############################################################################
#  Scénario Numéro 3 - Test de la concurence entre check_remote et le check_local
#
# Scénario de test pour valider :
#  1) Le verrouillage (lock file) lorsque 2 synchros se lancent
#     en même temps (périodique vs changement local).
#  2) La résolution de conflit (merge) si le remote a changé
#     pendant la modification locale.
#
# ############################################################################

######################################
# Préparation de l'environnement
######################################
echo "=== Setup initial ==="
rm -rf "$TMP_DIR"
if [ "$MODE_TEST" = "real" ]; then
    rclone delete "$REMOTE_DIR"
fi
mkdir -p "$LOCAL_DIR" "$REMOTE_DIR"

# On crée 2 fichiers identiques de base
echo "Initial A" > "$LOCAL_DIR/fileA.txt"
echo "Initial B" > "$LOCAL_DIR/fileB.txt"

# Copie initiale vers remote
if [ "$MODE_TEST" = "real" ]; then
    sync_remote
    sleep $SYNC_DELAY
else
    cp "$LOCAL_DIR"/* "$REMOTE_DIR"
fi

assert_file_exists "$REMOTE_DIR/fileA.txt"
assert_file_exists "$REMOTE_DIR/fileB.txt"

echo "[INFO] État initial local/remote OK."
echo

######################################
# CAS 1 : sync local puis trigger change
#
# 1) On lance une sync_local() (périodique),
#    qui prend le lock.
# 2) Pendant ce temps, un changement local
#    est détecté (on_change()), qui attend
#    le lock.
# 3) On ajoute un conflit : fileA modifié
#    sur remote en même temps.
######################################
echo "=== CAS 1 : sync local puis trigger change ==="


generate_checksums_remote_current
cp "$CHECKSUM_FILE_REMOTE_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"
generate_checksums_local

echo "Modified A remote" | rclone rcat "$REMOTE_DIR/fileA.txt"
check_local_loop &
check_remote_loop &

echo "Modified A local" > "$LOCAL_DIR/fileA.txt"

sleep 5


MERGED_CONTENT_CAS_1="$(cat <<'EOF'
_<<<<<<<<<<<<<
Modified A local
_>>>>>>>>>>>>>
Modified A remote

EOF
)"

assert_file_content "$LOCAL_DIR/fileA.txt" "$MERGED_CONTENT_CAS_1"
assert_file_content "$REMOTE_DIR/fileA.txt" "$MERGED_CONTENT_CAS_1"
echo "[INFO] Cas 1 Validé"
echo "--------------------------------------"


######################################
# CAS 2 : trigger change puis sync local
#
# 1) Un changement local est détecté (on_change()), qui prend le lock
# 2) Quasiment en même temps, la sync périodique remote->local se lance
#    mais ne peut pas prendre le lock.
# 3) On ajoute un autre conflit pour illustrer.
######################################

echo "=== CAS 2 : trigger change puis sync local ==="

generate_checksums_remote_current
cp "$CHECKSUM_FILE_REMOTE_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"
generate_checksums_local

# 1) L'utilisateur modifie localement fileA
echo "Local edit on A" > "$LOCAL_DIR/fileA.txt"

echo "Modified A remote" | rclone rcat "$REMOTE_DIR/fileA.txt"
check_remote_loop &

sleep 5

MERGED_CONTENT_CAS_2="$(cat <<'EOF'
_<<<<<<<<<<<<<
Local edit on A
_>>>>>>>>>>>>>
Modified A remote

EOF
)"


assert_file_content "$LOCAL_DIR/fileA.txt" "$MERGED_CONTENT_CAS_2"
assert_file_content "$REMOTE_DIR/fileA.txt" "$MERGED_CONTENT_CAS_2"
echo "[INFO] Cas 2 Validé"

rm -rf "$TMP_DIR" 2>/dev/null
rm -rf "$LOCK_FILE" 2>/dev/null
if [ "$MODE_TEST" = "real" ]; then
    rclone delete "$REMOTE_DIR"
fi
sleep 5

cleanup

