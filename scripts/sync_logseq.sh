#!/bin/bash

set -m
set -euo pipefail  #S'assure de la robustesse du script

PGID=$(ps -o pgid= $$ | grep -o '[0-9]*')

# Variable pour éviter les appels multiples à cleanup
CLEANUP_DONE=0

# Définir un trap pour capturer les signaux et effectuer le nettoyage
trap cleanup EXIT SIGINT SIGTERM SIGHUP

# Détermine le chemin absolu du répertoire du script
SCRIPT_DIR=$(dirname "$(realpath "$0")")
PROJECT_DIR="$SCRIPT_DIR/.."  # Répertoire racine du projet
CONFIG_DIR="$PROJECT_DIR/config"

# Dossiers de traitement temporaire
TMP_DIR=$(mktemp -d)

# Récupérer les variables d'environnement
source "$CONFIG_DIR/config.env"

# Mode de sortie (terminal ou fichier)
OUTPUT_MODE="file"  # Options: terminal, file


# Définir les répertoires basés sur le chemin du script
CHECKSUM_DIR="$PROJECT_DIR/checksums"
LOG_DIR="$PROJECT_DIR/sync_logs"

mkdir -p $CHECKSUM_DIR
mkdir -p $LOG_DIR

CHECKSUM_FILE_REMOTE_PREVIOUS="$CHECKSUM_DIR/checksums_remote_previous.txt"
CHECKSUM_FILE_REMOTE_CURRENT="$CHECKSUM_DIR/checksums_remote_current.txt"
CHECKSUM_FILE_LOCAL_CURRENT="$CHECKSUM_DIR/checksums_local_current.txt"

FILES_TO_SYNC="$CHECKSUM_DIR/cloud_files.txt"
LOCK_FILE="$TMP_DIR/sync.lock"
PATCH_DIR="$TMP_DIR/patches"

LOG_FILE="$LOG_DIR/sync.log"

# PID du processus `inotifywait`
INOTIFY_PID_FILE="$TMP_DIR/inotify.pid"
INOTIFY_LOOP_FILE="$TMP_DIR/inotify.loop"

source "$SCRIPT_DIR/functions.sh"

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

