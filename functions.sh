#!/usr/bin/env bash

##############################################################################
# 1) Fonctions d'assertion
##############################################################################

# Verifie si un fichier existe sur un remote ou local
assert_file_exists() {
  local file_path="$1"
  if rclone ls "$file_path" &>/dev/null; then
    echo "[OK] Le fichier '$file_path' existe bien."
  else
    echo "[ERR] Le fichier '$file_path' est introuvable."
    exit 1
  fi
}

# Verifie qu'un fichier n'existe PAS sur un remote ou local
assert_file_not_exists() {
  local file_path="$1"
  if rclone ls "$file_path" &>/dev/null; then
    echo "[ERR] Le fichier '$file_path' ne devrait pas exister, mais il est present."
    exit 1
  else
    echo "[OK] Le fichier '$file_path' n'existe pas (attendu)."
  fi
}

# Verifie que le contenu d'un fichier correspond à un attendu
assert_file_content() {
  local file_path="$1"
  local expected_content="$2"

  # Recupere le contenu du fichier en utilisant rclone
  local actual_content
  actual_content=$(rclone cat "$file_path" 2>/dev/null)

  if [[ $? -ne 0 ]]; then
    echo "[ERR] Fichier '$file_path' introuvable pour comparer le contenu."
    exit 1
  fi

  if [[ "$actual_content" == "$expected_content" ]]; then
    echo "[OK] Le contenu de '$file_path' correspond EXACTEMENT à l'attendu."
  else
    echo "[ERR] Le contenu de '$file_path' ne correspond pas à l'attendu."
    echo "----- Attendu :"
    echo "$expected_content"
    echo "----- Obtenu :"
    echo "$actual_content"
    echo "-----"
    exit 1
  fi
}



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
        timeout 2m rclone config reconnect GoogleDrivePersoSyncLogseq: --config="$CONFIG_PATH" "${RCLONE_LOG[@]}" --auto-confirm
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
# 2.1) Fonctions de synchronisation avec rclone
##############################################################################

# merge_local (merge du cloud vers local)
merge_local() {
    echo_log "Debut du merge_local"
    mkdir -p "$PATCH_DIR"
    awk '{print $NF}' $CHECKSUM_FILE_REMOTE_CURRENT > $FILES_TO_SYNC
    while read -r line; do
        local_checksum=$(echo "$line" | cut -d ' ' -f 1)
        file_path=$(echo "$line" | cut -d ' ' -f 2- | sed 's/^ *//')
        remote_file_path="$REMOTE_DIR/$file_path"
        local_file_path="$LOCAL_DIR/$file_path"
        #echo_log "file_path: $file_path"
        # On regarde dans les fichiers actuels locals, ceux qui ne sont pas presents dans l'ancien remote
        # En gros, les fichiers qui ont ete modifies sans etre mise à jour avant le download.
        # Pour ces fichiers, il faut faire un merge si le fichier remote existe. Sinon ne rien faire.
        remote_checksum_previous=$(grep "$file_path" "$CHECKSUM_FILE_REMOTE_PREVIOUS" | awk '{print $1}' || echo "")
        if [ "$local_checksum" != "$remote_checksum_previous" ]; then # Pas le meme checksum entre local et previous remote
            if grep -q "$file_path" "$CHECKSUM_FILE_REMOTE_PREVIOUS"; then # Check si le fichier conflictueux existait dans le previous remote
                if grep -q "$file_path" "$CHECKSUM_FILE_REMOTE_CURRENT"; then # Maintenant, Check si le fichier conflictueux existe dans le current remote
                    echo_log "Fichier conflictueux: $file_path"
                    rclone copyto "$remote_file_path" "$PATCH_DIR/$file_path.remote" --config="$CONFIG_PATH" "${RCLONE_LOG[@]}" #On copie le fichier remote en temporaire
                    merge_files "$LOCAL_DIR/$file_path" "$PATCH_DIR/$file_path.remote" "$file_path"
                    #sync local -> remote merged file overwriting the remote file
                    rclone copyto "$LOCAL_DIR/$file_path" "$remote_file_path" --config="$CONFIG_PATH" "${RCLONE_LOG[@]}"
                else #Le fichier conflictueux n'existe pas dans le current remote, on regarde alors si le checksum a change en local, ce qui voudrait dire la personne l'a modifie et souhaite le garder
                    remote_previous_checksum=$(grep "$file_path" "$CHECKSUM_FILE_REMOTE_PREVIOUS" | awk '{print $1}')
                    if [ "$local_checksum" != "$remote_previous_checksum" ]; then
                        echo_log "Conservation du fichier depuis local: $file_path"
                        echo "$file_path" >> "$FILES_TO_SYNC"
                    fi
                fi

            else # Le fichier conflit n'existait pas avant, il a ete cree par local et est à upload
                echo_log "Creation du fichier depuis local: $file_path"
                echo $file_path >> $FILES_TO_SYNC
            fi
        fi
    done < "$CHECKSUM_FILE_LOCAL_CURRENT"
    echo_log "Fin du merge_local"
}

# merge_remote (merge du local vers cloud)
merge_remote() {
    rclone copy "$LOCAL_DIR" "$REMOTE_DIR" --files-from $FILES_TO_SYNC --no-traverse "${RCLONE_LOG[@]}" --config="${CONFIG_PATH}"
}

# sync_local (synchroniser du cloud vers local)
sync_local() {
    echo_log "Synchronisation en cours (cloud -> local) ..."
    rclone sync "$REMOTE_DIR" "$LOCAL_DIR" \
        --fast-list \
        --config="${CONFIG_PATH}" \
        "${RCLONE_LOG[@]}"

    generate_checksums_local
}

# sync_remote (synchroniser du local vers cloud)
sync_remote(){
    echo_log "Synchronisation en cours (local -> cloud) ..."
    rclone sync "$LOCAL_DIR" "$REMOTE_DIR"  \
        --fast-list \
        --config="${CONFIG_PATH}" \
        "${RCLONE_LOG[@]}"

    generate_checksums_remote_current
    cp "$CHECKSUM_FILE_REMOTE_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"
}


##############################################################################
# 2.2) Fonctions de checksum 
##############################################################################

# Checksum du dossier $LOCAL_DIR
generate_checksums_local() {
    rclone hashsum MD5 "$LOCAL_DIR" > "$CHECKSUM_FILE_LOCAL_CURRENT"
    if [ ! -f "$CHECKSUM_FILE_LOCAL_CURRENT" ]; then
        echo_log "Error: Failed to create local checksum file for local directory. Exiting." 
        exit 1
    fi
}

generate_checksums_remote_current() {
    #rclone md5sum "$REMOTE_DIR" --config="${CONFIG_PATH}" 2>/dev/null > "$CHECKSUM_FILE_REMOTE_CURRENT"
    { rclone md5sum "$REMOTE_DIR" --config="${CONFIG_PATH}" "${RCLONE_LOG[@]}" > "$CHECKSUM_FILE_REMOTE_CURRENT"; } 2>&1
    if [ ! -f "$CHECKSUM_FILE_REMOTE_CURRENT" ]; then
        echo_log "Error: Failed to create local checksum file for remote directory. Exiting."
        exit 1
    fi
}

generate_checksums_remote_previous() {
    if [ ! -f "$CHECKSUM_FILE_REMOTE_PREVIOUS" ]; then
        generate_checksums_remote_current
        cp "$CHECKSUM_FILE_REMOTE_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"
    fi
}

debug_checksums(){
    echo_log "$CHECKSUM_FILE_REMOTE_PREVIOUS"
    cat "$CHECKSUM_FILE_REMOTE_PREVIOUS"
    echo
    echo_log "$CHECKSUM_FILE_REMOTE_CURRENT"
    cat "$CHECKSUM_FILE_REMOTE_CURRENT"
    echo
    echo_log "$CHECKSUM_FILE_LOCAL_CURRENT"
    cat "$CHECKSUM_FILE_LOCAL_CURRENT"
}

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

##############################################################################
# 2.4) Fonctions de fusion de fichiers
##############################################################################

merge_files() {
    local file1="$1"
    local file2="$2"
    local filename="$3"

    mkdir -p "$PATCH_DIR"

    echo_log "Fusion ligne par ligne en cours pour $file2 ..."

    # 1) Lecture de file1 et file2 dans des tableaux
    mapfile -t arr1 < "$file1"
    mapfile -t arr2 < "$file2"

    local len1=${#arr1[@]}
    local len2=${#arr2[@]}
    local i=0
    local j=0

    # Fonction utilitaire pour afficher un bloc conflictuel
    # entre arr1[i..i2-1] et arr2[j..j2-1].
    conflict_block() {
        local start1="$1"
        local end1="$2"
        local start2="$3"
        local end2="$4"

        echo "_<<<<<<<<<<<<<"
        # Toutes les lignes "differentes" côte file1
        for (( k = start1; k < end1; k++ )); do
            echo "${arr1[$k]}"
        done

        echo "_>>>>>>>>>>>>>"
        # Toutes les lignes "differentes" côte file2
        for (( k = start2; k < end2; k++ )); do
            echo "${arr2[$k]}"
        done

        # Saut de ligne pour separer le bloc
        echo ""
    }

    {
        # 2) Boucle principale : tant qu'on n'a pas epuise l'un des deux tableaux
        while [[ $i -lt $len1 && $j -lt $len2 ]]; do
            if [[ "${arr1[$i]}" == "${arr2[$j]}" ]]; then
                # Lignes identiques => on les affiche directement
                echo "${arr1[$i]}"
                ((i++))
                ((j++))

            else
                # 3) Difference => on cherche la prochaine ligne commune
                local foundCommon=false
                local i2=-1
                local j2=-1

                # Recherche brute de la prochaine ligne commune :
                # On balaie arr1[i..] vs arr2[j..] pour trouver la premiere occurrence
                # où arr1[x] == arr2[y].
                for (( x = i; x < len1; x++ )); do
                    # Pour chaque x, on parcourt arr2 du point j
                    for (( y = j; y < len2; y++ )); do
                        if [[ "${arr1[$x]}" == "${arr2[$y]}" ]]; then
                            i2=$x
                            j2=$y
                            foundCommon=true
                            break
                        fi
                    done || true
                    if $foundCommon; then
                        break
                    fi
                done || true

                if $foundCommon; then
                    # On a trouve une ligne commune aux deux fichiers "plus loin"

                    # => On cree un bloc de conflit entre
                    #    arr1[i..i2-1] et arr2[j..j2-1]
                    conflict_block "$i" "$i2" "$j" "$j2"

                    # Puis on recale i et j sur la ligne commune trouvee
                    # (SANS l’afficher ici, car elle sera traitee dans le cycle suivant)
                    i=$i2
                    j=$j2

                else
                    # 4) Aucune ligne commune jusqu'à la fin des deux fichiers
                    # => On met tout le reste dans un bloc de conflit
                    conflict_block "$i" "$len1" "$j" "$len2"

                    # On vide i et j pour sortir de la boucle
                    i=$len1
                    j=$len2
                fi
            fi
        done || true

        # 5) S'il reste des lignes dans file1 ou file2...
        #    Selon la logique Git, ce sont aussi des "conflits" si tout n'est pas commun.
        #    Vous pouvez sinon simplement les afficher sans marquage.
        
        if [[ $i -lt $len1 || $j -lt $len2 ]]; then
            # On met tout le reste dans un dernier bloc de conflit
            conflict_block "$i" "$len1" "$j" "$len2"
        fi

    } > "$PATCH_DIR/$filename.tmp"

    mv "$PATCH_DIR/$filename.tmp" "$file1"
    echo_log "Fusion avec marquage effectuee pour $file1"
}

handle_conflicts() {
    echo_log "Detection et gestion des conflits..."
    merge_local
    merge_remote
    sync_local
}

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
            if [ ! -f "$LOCK_FILE" ]; then
                on_change
            else
                echo_log "Le lockFile est present. Abandon de la trigger_changes_local"
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

trigger_changes_remote() {
    while true; do
        if ! check_internet ; then #Si l'internet n'est pas present
            break
        else
            if [ -f "$LOCK_FILE" ]; then #Si quelqu'un est dejà en train d'ecrire dans le repertoire
                echo_log "Le lockFile est present. Abandon de trigger_changes_remote"
                break
            else
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

##############################################################################
# 2.6) Fonctions de lancement des boucles
##############################################################################


check_init_loop(){
    while true; do
        if check_internet; then
            if check_remote_connection; then
                echo_log "Test de la connexion au remote réussite. Lancement de sync-logseq.service ...."
                exit 0
            else
                exit 1
            fi
        else
            echo_log "Pas de connexion. Nouvelle tentative de check_remote_loop dans $RETRY_INTERNET_INTERVAL secondes." 
            sleep "$RETRY_INTERNET_INTERVAL"
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

stop_inotify() {
    # Arreter inotifywait
    if [ -f "$INOTIFY_PID_FILE" ]; then
        kill "$(cat "$INOTIFY_PID_FILE")"
        rm -f "$INOTIFY_PID_FILE"
        echo_log "$(date)- Fin de surveillance de $LOCAL_DIR..." 
    fi
}

rotate_logs() {
    local log_file="$1"    # Chemin du fichier de log
    local max_size=10024   # Taille max en octets (10 Ko ici)
    local max_files=3      # Nombre maximum de fichiers à conserver

    # Verifier si la taille du fichier depasse la limite
    if [ -f "$log_file" ] && [ "$(stat -c%s "$log_file")" -ge "$max_size" ]; then
        echo "$(date) - Rotation du fichier de log $log_file..."

        # Deplacer les anciens fichiers (log.2 -> log.3, log.1 -> log.2, etc.)
        for ((i=max_files; i>1; i--)); do
            if [ -f "${log_file}.$((i-1))" ]; then
                mv "${log_file}.$((i-1))" "${log_file}.$i"
            fi
        done

        # Sauvegarder le fichier actuel avec le suffixe .1
        mv "$log_file" "${log_file}.1"

        # Recreer le fichier de log vide
        > "$log_file"
    fi
}


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
        rm -rf "$TMP_DIR" 2>/dev/null
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

rotate_logs_loop() {
    # Exemple de boucle principale avec rotation des logs
    while true; do

        # Gérer le roulement des logs
        rotate_logs "$LOG_FILE"

        # Pause entre deux itérations
        sleep 1
    done
}



