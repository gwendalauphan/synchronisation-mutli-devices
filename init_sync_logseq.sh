#!/bin/bash

set -m
set -euo pipefail  #S'assure de la robustesse du script

PGID=$(ps -o pgid= $$ | grep -o '[0-9]*')

# Variable pour éviter les appels multiples à cleanup
CLEANUP_DONE=0

# Fonction de nettoyage à appeler lors de l'interruption
cleanup_init() {
    if [ $CLEANUP_DONE -eq 0 ]; then
        local SIGN=${1:-1}  # Assigne 1 à SIGN si aucun argument n'est fourni #Il faut mettre SIGN=1 par défaut 
        CLEANUP_DONE=1
        echo_log "Le script a été interrompu. Nettoyage en cours..."
        rm -rf "$TMP_DIR" 2>/dev/null

        # -- Tuer recursivement tous les processus enfants --
        echo_log "Tuer tous les processus du groupe $$"
        # On recupere tous les PID enfants directs du script
        for child_pid in $(pgrep -P $$); do
            killtree "$child_pid" -TERM
        done
        
        # -- Facultatif : si tu veux tuer aussi le script lui-meme,
        #    ainsi que tout le groupe associe --
        pkill -TERM -g "$PGID" 2>/dev/null

        exit $SIGN
    fi
}


# Définir un trap pour les signaux d'interruption courants
trap cleanup_init EXIT SIGINT SIGTERM SIGHUP

# Détermine le chemin absolu du répertoire du script
SCRIPT_DIR=$(dirname "$(realpath "$0")")

# Dossiers de traitement temporaire
TMP_DIR=$(mktemp -d)

# Récupérer les variables d'environnement
source "$SCRIPT_DIR/config.env"

# Mode de sortie (terminal ou fichier)
OUTPUT_MODE="file"  # Options: terminal, file

# Définir les répertoires basés sur le chemin du script
LOG_DIR="$SCRIPT_DIR/sync_logs"

LOG_FILE="$LOG_DIR/sync.log"

source "$SCRIPT_DIR/functions.sh"

echo_log "Lancement de init_sync_logseq.sh"

rotate_logs_loop &
rotate_logs_loop_pid=$!

check_init_loop &
check_init_loop_pid=$!

echo "PGID: $PGID"
pgrep=$(pgrep -P $$)

for child_pid in $pgrep; do
    echo "child $child_pid"
    echo $(ps -eo pid,pgid,ppid,comm | grep "$child_pid")
done

if [ "$PPID" -ne 1 ]; then
    echo "Processus parent (PID : $PPID)..."
fi

# Attente des processus enfants et gestion des erreurs
for pid in "$check_init_loop_pid" "$rotate_logs_loop_pid"; do
    if wait "$pid"; then
        echo "Le processus enfant $pid s'est terminé avec succès."
        cleanup_init 0
    else
        echo "Erreur détectée dans le processus enfant $pid." >&2
        exit 1
    fi
done