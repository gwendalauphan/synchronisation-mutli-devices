#!/usr/bin/env bash

source "$SCRIPT_DIR/check_remote.sh"
source "$SCRIPT_DIR/functions.sh"
source "$SCRIPT_DIR/utils.sh"

##############################################################################
# 2.5) Fonctions de detection de changement en local
##############################################################################

on_change() {
    touch "$LOCK_FILE"
    echo_log "Modifications detectees dans $LOCAL_DIR"
    # Delai pour eviter plusieurs detections rapides
    sleep "$SYNC_DELAY"
    generate_checksums_local
    generate_checksums_remote_previous
    generate_checksums_remote_current
    if detect_changes_remote; then #conflits
        echo_log "Conflits à corriger !! - Merge en cours ..." # merge à faire
        handle_conflicts
    else
        sync_remote
    fi
    rm -f "$LOCK_FILE"
}


trigger_changes_local() {
    echo "true" > "$INOTIFY_LOOP_FILE"
    echo_log "Surveillance de $LOCAL_DIR..."
    inotifywait -r -e modify,create,delete,move  --format '%w%f' "$LOCAL_DIR" | while read file
    do
        if check_internet; then
            lock_attempts=0
            if [ -f "$LOCK_ATTEMPTS_FILE" ]; then
                lock_attempts=$(cat "$LOCK_ATTEMPTS_FILE")
            fi
            if [ ! -f "$LOCK_FILE" ]; then
                echo 0 > "$LOCK_ATTEMPTS_FILE"
                on_change
            else
                lock_attempts=$((lock_attempts + 1))
                echo "$lock_attempts" > "$LOCK_ATTEMPTS_FILE"
                echo_log "Le lockFile est present. Abandon de la trigger_changes_local (tentative $lock_attempts/10)"
                if [ "$lock_attempts" -ge 10 ]; then
                    echo_log "Lockfile bloqué 10 fois, redémarrage du service..."
                    echo_log "ERROR - Code de sortie 1 pour systemd"
                    exit 1
                fi
            fi
        else
            echo_log "Pas de connexion Internet. Echec de la synchronisation"
            break
        fi
        echo_log "inotifywait s'est arrete. Redemarrage..."
        rm -f "$INOTIFY_LOOP_FILE"
    done &
    echo $! > "$INOTIFY_PID_FILE"
}


check_local_loop() {
    while true; do
        if [ -f "$INOTIFY_LOOP_FILE" ]; then
            sleep $DELAY_RESTART_NEW_INOTIFY
        else
            if check_internet; then
                trigger_changes_local
                sleep $DELAY_RESTART_TRIGGER_CHANGES_LOCAL
            else
                echo_log "Pas de connexion. Nouvelle tentative de check_local_loop dans $RETRY_INTERNET_INTERVAL secondes."
                sleep "$RETRY_INTERNET_INTERVAL"
            fi
        fi
    done
}