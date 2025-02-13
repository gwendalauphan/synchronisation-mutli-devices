#!/bin/bash

TMP_FILE="/tmp/sync_temp.txt"



######------ LIBS FUNCIONS ------########

# Fonction pour vérifier la connexion Internet
check_internet() {
    if ping -c 1 google.com &>/dev/null; then
        return 0  # Connecté
    else
        return 1  # Pas de connexion
    fi
}

######------ INIT ---------######

init() {
    # Créer le dossier de test s'il n'existe pas
    mkdir -p "$WATCH_DIR"

    # Créer un fichier de test s'il n'existe pas
    if [ ! -f "$WATCH_DIR/$WATCH_FILE" ]; then
        echo "Création de $WATCH_FILE pour les tests..." > "$WATCH_DIR/$WATCH_FILE"
    fi
}


######------- COMPARE FILE1 & FILE2 ------########

# Fonction de merge en cas de conflit (ligne par ligne)
merge_files() {
    local file1="$1"
    local file2="$2"

    echo "Fusion ligne par ligne en cours pour $file2 ..."

    # Créer un fichier temporaire pour enregistrer les différences
    diff_output=$(diff -u "$file2" "$file1")

    # Si diff retourne des différences
    if [ -n "$diff_output" ]; then
        # Appliquer le patch des différences
        echo "$diff_output" > /tmp/diff.patch
        patch "$file2" < /tmp/diff.patch

        # Afficher le message de succès
        echo "Fusion réussie pour $file2"
    else
        echo "Aucune différence détectée, pas de fusion nécessaire."
    fi
}



fetch_remote_changes() {
    local remote_file="$RCLONE_REMOTE/$WATCH_FILE"
    local remote_md5
    local local_md5

    echo "$(date) - Vérification des modifications distantes..." | tee -a "$LOG_FILE"

    # Vérifier si le fichier distant existe avec rclone lsf
    if rclone lsf "$remote_file" --config="${CONFIG_PATH}" 2>/dev/null | grep -q "$WATCH_FILE"; then
        
        # Récupérer les checksums
        remote_md5=$(rclone md5sum "$remote_file" --config="${CONFIG_PATH}" 2>/dev/null | awk '{print $1}')
        local_md5=$(md5sum "$WATCH_DIR/$WATCH_FILE" | awk '{print $1}')

        # Comparer les checksums
        if [ "$remote_md5" != "$local_md5" ]; then
            echo "$(date) - Différences détectées (checksum). Fusion en cours..." | tee -a "$LOG_FILE"
            
            # Télécharger directement et effectuer le merge
            rclone copyto "$remote_file" "$TMP_FILE" --log-file="$LOG_FILE" --config="${CONFIG_PATH}" 2>/dev/null
            
            if [ -s "$TMP_FILE" ]; then
                merge_files "$TMP_FILE" "$WATCH_DIR/$WATCH_FILE"
                sync_file
            fi
        else
            echo "$(date) - Aucun changement distant (checksum identique)." | tee -a "$LOG_FILE"
        fi
    else
        echo "$(date) - Fichier distant inexistant." | tee -a "$LOG_FILE"
    fi
}


# Fonction de synchronisation avec rclone et gestion des conflits
sync_file() {
    local remote_file="$RCLONE_REMOTE/$WATCH_FILE"

    # Copier la version distante pour vérifier s'il y a un conflit
    rclone copy "$remote_file" "$TMP_FILE" --config="${CONFIG_PATH}" --log-file="$LOG_FILE" 2>/dev/null

    if [ -f "$TMP_FILE" ]; then
        echo "$(date) - Conflit détecté, fusion en cours..." | tee -a "$LOG_FILE"
        merge_files "$TMP_FILE" "$WATCH_DIR/$WATCH_FILE"
    fi

    # Synchronisation finale après merge
    rclone sync "$WATCH_DIR/$WATCH_FILE" "$RCLONE_REMOTE" \
      --config="${CONFIG_PATH}" \
      --update --verbose --log-file="$LOG_FILE"

    if [ $? -eq 0 ]; then
        echo "$(date) - Synchronisation réussie." | tee -a "$LOG_FILE"
    else
        echo "$(date) - Échec de la synchronisation." | tee -a "$LOG_FILE"
    fi
}



# Fonction exécutée lors de la modification du fichier
on_change() {
    echo "$(date) - Modification détectée dans $WATCH_FILE" | tee -a "$LOG_FILE"

    # Vérification de la connexion et boucle de retry
    while true; do
        if check_internet; then
            echo "$(date) - Connexion Internet détectée, synchronisation en cours..." | tee -a "$LOG_FILE"
            sync_file
            break
        else
            echo "$(date) - Pas de connexion. Nouvelle tentative dans 1 minute." | tee -a "$LOG_FILE"
            sleep "$RETRY_INTERVAL"
        fi
    done
}

# Vérification régulière du remote pour les mises à jour
check_remote_periodically() {
    while true; do
        if check_internet; then
            fetch_remote_changes
        fi
        sleep "$REMOTE_CHECK_INTERVAL"
    done
}

# Démarrer la vérification du remote en arrière-plan
check_remote_periodically &

# Lancer la surveillance avec inotifywait
echo "$(date) - Surveillance du fichier $WATCH_FILE dans $WATCH_DIR..." | tee -a "$LOG_FILE"
inotifywait -m -e modify --format '%w%f' "$WATCH_DIR/$WATCH_FILE" | while read -r file; do
    # Délai pour éviter plusieurs détections rapides
    sleep "$SYNC_DELAY"
    on_change
    echo "test inotify"
done
