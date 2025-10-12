#!/bin/bash

set -m
set -euo pipefail  #S'assure de la robustesse du script

# Détermine le chemin absolu du répertoire du script
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="$SCRIPT_DIR/.."  # Répertoire racine du projet
DATA_DIR="$PROJECT_DIR/data"
CONFIG_DIR="$PROJECT_DIR/config"

# Mode de sortie (terminal ou fichier)
OUTPUT_MODE="file"  # Options: terminal, file

# Dossiers de traitement temporaire
TMP_DIR=$(mktemp -d)

# Définir les répertoires basés sur le chemin du script
CHECKSUM_DIR="$DATA_DIR/checksums"
LOG_DIR="$DATA_DIR/sync_logs"

mkdir -p $CHECKSUM_DIR
mkdir -p $LOG_DIR

# chargement de la config
source "$SCRIPT_DIR/config.sh"

# Récupérer les variables d'environnement
source "$CONFIG_DIR/config.env"

source "$SCRIPT_DIR/functions.sh"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/check_local.sh"
source "$SCRIPT_DIR/check_remote.sh"
source "$SCRIPT_DIR/rotate_logs.sh"

# Définir un trap pour capturer les signaux et effectuer le nettoyage
trap cleanup EXIT SIGINT SIGTERM SIGHUP

# ---------- End of config section ---------- #


# Démarrage des processus enfants
check_remote_loop &
check_remote_loop_pid=$!

check_local_loop &
check_local_loop_pid=$!

rotate_logs_loop &
rotate_logs_loop_pid=$!

echo "Processus enfants lancés :"
echo "  check_remote_loop : PID $check_remote_loop_pid"
echo "  check_local_loop : PID $check_local_loop_pid"
echo "  rotate_logs_loop : PID $rotate_logs_loop_pid"

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
for pid in "$check_remote_loop_pid" "$check_local_loop_pid" "$rotate_logs_loop_pid"; do
    wait "$pid" || {
        echo "Erreur détectée dans le processus enfant $pid." >&2
        #cleanup
        #exit 1
    }
done

