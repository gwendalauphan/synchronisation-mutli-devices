#!/bin/bash

# Récupérer les variables d'environnement
source ./config.env

# Mode de sortie (terminal ou fichier)
OUTPUT_MODE="terminal"  # Options: terminal, file

# Dossiers synchronisés
LOCAL_DIR=$WATCH_DIR
REMOTE_DIR=$RCLONE_REMOTE

# Dossiers de traitement temporaire
CHECKSUM_FILE_REMOTE_PREVIOUS="/tmp/checksums_remote_previous.txt"
CHECKSUM_FILE_REMOTE_CURRENT="/tmp/checksums_remote_current.txt"
CHECKSUM_FILE_LOCAL_CURRENT="/tmp/checksums_local_current.txt"
FILES_TO_SYNC="/tmp/cloud_files.txt"
PATCH_DIR="/tmp/patches"



if [ "$OUTPUT_MODE" = "file" ]; then
    LOG_CMD="tee -a \"$LOG_FILE\""
    RCLONE_LOG="--verbose --log-file=\"$LOG_FILE\""
    
else
    LOG_CMD="cat"
    RCLONE_LOG="--log-level INFO"
fi

echo_log() {
    echo "$(date) - $1" | eval "$LOG_CMD"
}


# Checksum du dossier $LOCAL_DIR
generate_checksums_local() {
    rclone hashsum MD5 "$LOCAL_DIR" > "$CHECKSUM_FILE_LOCAL_CURRENT"
    if [ ! -f "$CHECKSUM_FILE_LOCAL_CURRENT" ]; then
        echo_log "Error: Failed to create local checksum file for local directory. Exiting." 
        exit 1
    fi

}

generate_checksums_remote_current() {
    rclone md5sum "$REMOTE_DIR" --config="${CONFIG_PATH}" 2>/dev/null > "$CHECKSUM_FILE_REMOTE_CURRENT"
    if [ ! -f "$CHECKSUM_FILE_REMOTE_CURRENT" ]; then
        echo_log "Error: Failed to create local checksum file for remote directory. Exiting."
        exit 1
    fi
}

# Vérifier la connexion Internet
check_internet() {
    if ping -c 1 google.com &>/dev/null; then
        return 0  # Connecté
    else
        return 1  # Pas de connexion
    fi
}

# sync_local (synchroniser du cloud vers local)
sync_local() {
    rclone sync "$REMOTE_DIR" "$LOCAL_DIR" --fast-list $RCLONE_LOG --config="${CONFIG_PATH}"
    generate_checksums_local
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

detect_changes_remote() {
    if [ ! -f "$CHECKSUM_FILE_REMOTE_PREVIOUS" ] || [ ! -f "$CHECKSUM_FILE_REMOTE_CURRENT" ]; then
        echo_log "No previous or current remote checksum file found."
        exit 1
    fi

    if cmp -s "$CHECKSUM_FILE_REMOTE_PREVIOUS" "$CHECKSUM_FILE_REMOTE_CURRENT"; then
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

    if cmp -s "$CHECKSUM_FILE_LOCAL_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"; then
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

    if cmp -s "$CHECKSUM_FILE_LOCAL_CURRENT" "$CHECKSUM_FILE_REMOTE_CURRENT"; then
        echo_log "No changes detected between local current and current remote."
        return 1
    else
        echo_log "Changes detected between local current and current remote."
        return 0
    fi
}


generate_checksums_local
generate_checksums_remote_current
debug_checksums

detect_changes_remote
detect_changes_local_current_previous_remote
detect_changes_local_current_current_remote

merge_files() {
    local file1="$1"
    local file2="$2"
    local filename="$3"

    mkdir -p "$PATCH_DIR"

    echo "Fusion ligne par ligne en cours pour $file2 ..."

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

        echo "<<<<<<<<<<<<<"
        # Toutes les lignes "différentes" côté file1
        for (( k = start1; k < end1; k++ )); do
            echo "${arr1[$k]}"
        done

        echo ">>>>>>>>>>>>>"
        # Toutes les lignes "différentes" côté file2
        for (( k = start2; k < end2; k++ )); do
            echo "${arr2[$k]}"
        done

        # Saut de ligne pour séparer le bloc
        echo ""
    }

    {
        # 2) Boucle principale : tant qu'on n'a pas épuisé l'un des deux tableaux
        while [[ $i -lt $len1 && $j -lt $len2 ]]; do
            if [[ "${arr1[$i]}" == "${arr2[$j]}" ]]; then
                # Lignes identiques => on les affiche directement
                echo "${arr1[$i]}"
                ((i++))
                ((j++))

            else
                # 3) Différence => on cherche la prochaine ligne commune
                local foundCommon=false
                local i2=-1
                local j2=-1

                # Recherche brute de la prochaine ligne commune :
                # On balaie arr1[i..] vs arr2[j..] pour trouver la première occurrence
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
                    done
                    if $foundCommon; then
                        break
                    fi
                done

                if $foundCommon; then
                    # On a trouvé une ligne commune aux deux fichiers "plus loin"

                    # => On crée un bloc de conflit entre
                    #    arr1[i..i2-1] et arr2[j..j2-1]
                    conflict_block "$i" "$i2" "$j" "$j2"

                    # Puis on recale i et j sur la ligne commune trouvée
                    # (SANS l’afficher ici, car elle sera traitée dans le cycle suivant)
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
        done

        # 5) S'il reste des lignes dans file1 ou file2...
        #    Selon la logique Git, ce sont aussi des "conflits" si tout n'est pas commun.
        #    Vous pouvez sinon simplement les afficher sans marquage.

        if [[ $i -lt $len1 || $j -lt $len2 ]]; then
            # On met tout le reste dans un dernier bloc de conflit
            conflict_block "$i" "$len1" "$j" "$len2"
        fi

    } > "$PATCH_DIR/$filename.tmp"

    mv "$PATCH_DIR/$filename.tmp" "$file2"
    echo "Fusion avec marquage effectuée pour $file2"
}

merge_local() {
    mkdir -p "$PATCH_DIR"
    awk '{print $NF}' $CHECKSUM_FILE_REMOTE_CURRENT > $FILES_TO_SYNC
    while read -r line; do
        local_checksum=$(echo "$line" | awk '{print $1}')
        file_path=$(echo "$line" | awk '{print $2}')
        remote_file_path="$REMOTE_DIR/$file_path"
        local_file_path="$LOCAL_DIR/$file_path"
        # On regarde dans les fichiers actuels locals, ceux qui ne sont pas présents dans l'ancien remote
        # En gros, les fichiers qui ont été modifiés sans être mise à jour avant le download.
        # Pour ces fichiers, il faut faire un merge si le fichier remote existe. Sinon ne rien faire.
        remote_checksum_previous=$(grep "$file_path" "$CHECKSUM_FILE_REMOTE_PREVIOUS" | awk '{print $1}')
        if [ "$local_checksum" != "$remote_checksum_previous" ]; then # Pas le même checksum entre local et previous remote
            if grep -q "$file_path" "$CHECKSUM_FILE_REMOTE_PREVIOUS"; then # Check si le fichier conflictueux existait dans le previous remote
                if grep -q "$file_path" "$CHECKSUM_FILE_REMOTE_CURRENT"; then # Maintenant, Check si le fichier conflictueux existe dans le current remote
                    rclone copyto "$remote_file_path" "$PATCH_DIR/$file_path.remote"  --config="$CONFIG_PATH" #On copie le fichier remote en temporaire
                    merge_files "$PATCH_DIR/$file_path.remote" "$LOCAL_DIR/$file_path" "$file_path"
                fi

            else # Le fichier conflit n'existait pas avant, il a été créé par local et est à upload
                echo_log "Conservation du fichier $file_path"
                echo $file_path >> $FILES_TO_SYNC
            fi
        fi
    done < "$CHECKSUM_FILE_LOCAL_CURRENT"
}

merge_remote() {
    rclone copy "$LOCAL_DIR" "$REMOTE_DIR" --files-from $FILES_TO_SYNC --no-traverse $RCLONE_LOG
}

handle_conflicts() {
    echo_log "Détection et gestion des conflits..."
    merge_local
    merge_remote
    sync_local
}

# Vérification régulière du remote pour les mises à jour
check_remote_periodically() {
    if [ ! -f "$CHECKSUM_FILE_REMOTE_PREVIOUS" ]; then
        generate_checksums_remote_current
        cp "$CHECKSUM_FILE_REMOTE_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"
    fi
    while true; do
        generate_checksums_local
        if check_internet; then
            generate_checksums_remote_current
            if detect_changes_remote; then # la donnée a changée entre les 2 temps de connexion
                if detect_changes_local_current_previous_remote; then # Conflits présents 
                    echo_log "Conflits à corriger !! - Merge en cours ..." # merge à faire
                    handle_conflicts 
                else # Pas de conflits
                    echo_log "Synchronisation en cours ..." # sync cloud ->  local
                    sync_local
                fi
                cp "$CHECKSUM_FILE_REMOTE_CURRENT" "$CHECKSUM_FILE_REMOTE_PREVIOUS"
            fi
            echo "New sync in $REMOTE_CHECK_INTERVAL seconds ..."
        else
            echo_log "No Internet connection - Retry in $REMOTE_CHECK_INTERVAL seconds ..."
        fi 
        
        sleep "$REMOTE_CHECK_INTERVAL"
    done
}

trigger_changes_local() {
    while true; do
        echo_log "Surveillance de $WATCH_DIR..." 
        inotifywait -r -e modify,create,delete,move  --format '%w%f' "$LOCAL_DIR" | while read file
        do
            sync_remote
        done
        echo_log "inotifywait s'est arrêté. Redémarrage..." 
        sleep 2
    done
}
