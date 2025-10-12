#!/usr/bin/env bash

source "$SCRIPT_DIR/utils.sh"

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
                echo_log "Creation du fichier sur remote depuis local: $file_path"
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
    echo_log "Synchronisation terminee."
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

        echo "_<<<<<<<<<<<<< from local"
        # Toutes les lignes "differentes" côté file1
        for (( k = start1; k < end1; k++ )); do
            echo "${arr1[$k]}"
        done

        echo "=============="  # Separator between local and remote

        # Toutes les lignes "differentes" côté file2
        for (( k = start2; k < end2; k++ )); do
            echo "${arr2[$k]}"
        done
        echo "_>>>>>>>>>>>>> from remote"

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
