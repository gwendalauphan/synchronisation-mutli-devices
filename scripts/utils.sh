#!/usr/bin/env bash

##############################################################################
# 2.1) Fonctions generiques
##############################################################################

if [ "$OUTPUT_MODE" = "file" ]; then
    LOG_CMD="tee -a \"$LOG_FILE\""
    RCLONE_LOG=(--verbose --log-file="$LOG_FILE")
else
    LOG_CMD="cat"
    RCLONE_LOG=(--log-level INFO)
fi

echo_log() {
    echo "$(date) - $1" | eval "$LOG_CMD"
}

# Verifier la connexion Internet
check_internet() {
    if ping -c 1 google.com &>/dev/null; then
        return 0  # Connecte
    else
        return 1  # Pas de connexion
    fi
}

check_remote_connection(){
    rclone ls "$REMOTE_DIR" --config="$CONFIG_PATH" "${RCLONE_LOG[@]}" > /dev/null 2>&1
    STATUS=$?
    if [ ! $STATUS -eq 0 ]; then
        echo_log "ERROR - $REMOTE_DIR is unreachable"
        timeout 2m rclone config reconnect "$REMOTE_DIR" --config="$CONFIG_PATH" "${RCLONE_LOG[@]}" --auto-confirm
        if [ $? -eq 0 ]; then
            echo_log "Reconnexion réussie."
        else
            echo_log "Échec de la reconnexion."
            exit 1
        fi
    else
        return 0
    fi
}

##############################################################################
# 2.4) Fonctions de gestion de gestion d'erreurs
##############################################################################


# Fonction pour demarrer inotifywait en arriere-plan
stop_inotify() {
    # Arreter inotifywait
    if [ -f "$INOTIFY_PID_FILE" ]; then
        kill "$(cat "$INOTIFY_PID_FILE")"
        rm -f "$INOTIFY_PID_FILE"
        echo_log "$(date)- Fin de surveillance de $LOCAL_DIR..."
    fi
}

# Fonction pour tuer un processus et tous ses enfants
killtree() {
    local _pid="$1"
    local _sig="${2:--TERM}"   # Par defaut on envoie un -TERM si rien n’est precise

    # 1. Stopper le processus parent (_pid) pour qu’il ne fork pas de nouveaux enfants
    kill -STOP "${_pid}" 2>/dev/null

    # 2. Recuperer la liste de tous les PID enfants
    for _child in $(ps -o pid= --ppid "${_pid}" 2>/dev/null); do
        killtree "${_child}" "${_sig}"
    done

    # 3. Tuer le parent (en dernier)
    kill "${_sig}" "${_pid}" 2>/dev/null
}

# Fonction executee à la fin du script pour tuer tous les processus enfants
cleanup() {
    if [ $CLEANUP_DONE -eq 0 ]; then
        CLEANUP_DONE=1
        
        # -- Nettoyage des fichiers temporaires, lock, etc. --
        #rm -rf "$TMP_DIR" 2>/dev/null
        rm -rf "$REMOTE_DIR" 2>/dev/null
        rm -rf "$LOCK_FILE" 2>/dev/null
        if [ -n "${MODE_TEST:-}" ] && [ "$MODE_TEST" = "real" ]; then
            rclone delete "$REMOTE_DIR"
        fi

        sleep 2
        
        # -- Tuer recursivement tous les processus enfants --
        echo_log "Tuer tous les processus descendants du groupe $$"
        # On recupere tous les PID enfants directs du script
        for child_pid in $(pgrep -P $$); do
            killtree "$child_pid" -TERM
        done

        # -- Facultatif : si tu veux tuer aussi le script lui-meme,
        #    ainsi que tout le groupe associe --
        pkill -TERM -g "$PGID" 2>/dev/null
        
        # Sur la plupart des systemes, trap EXIT fera ensuite sortir proprement.
        
        # Retourne un code de sortie non nul pour signaler une erreur à systemd
        exit 1
    fi
}