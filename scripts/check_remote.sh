#!/usr/bin/env bash

source "$SCRIPT_DIR/functions.sh"
source "$SCRIPT_DIR/utils.sh"

##############################################################################
# 2.3) Fonctions de detection de changement en remote
##############################################################################

detect_changes_remote() {
    if [ ! -f "$CHECKSUM_FILE_REMOTE_PREVIOUS" ] || [ ! -f "$CHECKSUM_FILE_REMOTE_CURRENT" ]; then
        echo_log "No previous or current remote checksum file found."
        exit 1
    fi

    if cmp -s <(sort "$CHECKSUM_FILE_REMOTE_PREVIOUS") <(sort "$CHECKSUM_FILE_REMOTE_CURRENT"); then
        echo_log "No changes detected - remote."
        return 1
    else
        echo_log "Changes detected - remote."
        return 0
    fi
}

detect_changes_local_current_previous_remote() {
    if [ ! -f "$CHECKSUM_FILE_REMOTE_PREVIOUS" ] || [ ! -f "$CHECKSUM_FILE_LOCAL_CURRENT" ]; then
        echo_log "No current local or previous remote checksum file found. "
        exit 1
    fi

    if cmp -s <(sort "$CHECKSUM_FILE_LOCAL_CURRENT") <(sort "$CHECKSUM_FILE_REMOTE_PREVIOUS"); then
        echo_log "No changes detected between local current and previous remote."
        return 1
    else
        echo_log "Changes detected between local current and previous remote."
        return 0
    fi
}

detect_changes_local_current_current_remote() {
    if [ ! -f "$CHECKSUM_FILE_REMOTE_CURRENT" ] || [ ! -f "$CHECKSUM_FILE_LOCAL_CURRENT" ]; then
        echo_log "No current local or current remote checksum file found. "
        exit 1
    fi

    if cmp -s <(sort "$CHECKSUM_FILE_LOCAL_CURRENT") <(sort "$CHECKSUM_FILE_REMOTE_CURRENT"); then
        echo_log "No changes detected between local current and current remote."
        return 1
    else
        echo_log "Changes detected between local current and current remote."
        return 0
    fi
}


trigger_changes_remote() {
    remote_lock_attempts=0
    if [ -f "$LOCK_ATTEMPTS_REMOTE_FILE" ]; then
        remote_lock_attempts=$(cat "$LOCK_ATTEMPTS_REMOTE_FILE")
    fi
    while true; do
        if ! check_internet ; then #Si l'internet n'est pas present
            break
        else
            if [ -f "$LOCK_FILE" ]; then #Si quelqu'un est dejà en train d'ecrire dans le repertoire
                remote_lock_attempts=$((remote_lock_attempts + 1))
                echo "$remote_lock_attempts" > "$LOCK_ATTEMPTS_REMOTE_FILE"
                echo_log "Le lockFile est present. Abandon de trigger_changes_remote (tentative $remote_lock_attempts/30)"
                if [ "$remote_lock_attempts" -ge 30 ]; then
                    echo_log "Lockfile bloqué 30 fois, redémarrage du service..."
                    echo_log "ERROR - Code de sortie 1 pour systemd"
                    exit 1
                fi
                break
            else
                echo 0 > "$LOCK_ATTEMPTS_REMOTE_FILE"
                touch "$LOCK_FILE"
                generate_checksums_local
                generate_checksums_remote_previous
                generate_checksums_remote_current
                if detect_changes_remote; then # la donnee a changee entre les 2 temps de connexion
                    sleep 1
                    stop_inotify
                    if detect_changes_local_current_previous_remote; then # Conflits presents
                        echo_log "Conflits à corriger !! - Merge en cours ..." # merge à faire
                        handle_conflicts
                    else # Pas de conflits
                        sync_local
                    fi
                    rm -f "$INOTIFY_LOOP_FILE"
                    cp "$CHECKSUM_FILE_REMOTE_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"
                elif detect_changes_local_current_current_remote; then #Fichiers differents entre local et remote
                    sleep 1
                    stop_inotify
                    sync_remote
                    rm -f "$INOTIFY_LOOP_FILE"
                fi
                rm -f "$LOCK_FILE"
                echo_log "New sync in $REMOTE_CHECK_INTERVAL seconds ..."
                sleep "$REMOTE_CHECK_INTERVAL"
            fi
        fi
    done
}


check_remote_loop() {
    while true; do
        if check_internet; then
            trigger_changes_remote
            echo_log "New sync in $DELAY_RESTART_TRIGGER_CHANGES_REMOTE seconds ..."
            sleep $DELAY_RESTART_TRIGGER_CHANGES_REMOTE
        else
            echo_log "Pas de connexion. Nouvelle tentative de check_remote_loop dans $RETRY_INTERNET_INTERVAL secondes."
            sleep "$RETRY_INTERNET_INTERVAL"
        fi
    done
}