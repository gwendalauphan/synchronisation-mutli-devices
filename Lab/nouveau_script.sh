#!/bin/bash

source ./config.env

LOCAL_DIR=$WATCH_DIR
REMOTE_DIR=$RCLONE_REMOTE

CHECKSUM_FILE="/tmp/checksums.txt"
PATCH_DIR="/tmp/patches"

mkdir -p "$PATCH_DIR"

# Fonction pour générer les checksums
generate_checksums() {
    rclone hashsum MD5 "$LOCAL_DIR" > "$CHECKSUM_FILE"
}

# Fonction pour comparer les checksums avant upload
check_conflict() {
    local_changed=0
    remote_changed=0

    # Comparer chaque fichier local avec le checksum enregistré
    while read -r line; do
        local_hash=$(echo "$line" | awk '{print $1}')
        file=$(echo "$line" | awk '{print $2}')

        if [ -f "$LOCAL_DIR/$file" ]; then
            current_hash=$(rclone hashsum MD5 "$LOCAL_DIR/$file" --config="${CONFIG_PATH}" | awk '{print $1}')

            if [ "$local_hash" != "$current_hash" ]; then
                # Vérifier si le fichier a également changé en distant
                remote_hash=$(rclone hashsum MD5 "$REMOTE_DIR/$file" --config="${CONFIG_PATH}" | awk '{print $1}')

                if [ "$remote_hash" != "$local_hash" ]; then
                    echo "Conflit détecté pour : $file"
                    local_changed=1
                    remote_changed=1

                    # Télécharger la version distante
                    rclone copy "$REMOTE_DIR/$file" "$PATCH_DIR/$file.remote" --config="${CONFIG_PATH}"
                    
                    # Créer un patch basé sur les différences
                    diff_output=$(diff -u "$PATCH_DIR/$file.remote" "$LOCAL_DIR/$file")

                    if [ -n "$diff_output" ]; then
                        echo "$diff_output" > "$PATCH_DIR/$file.patch"
                        patch "$LOCAL_DIR/$file" < "$PATCH_DIR/$file.patch"
                        echo "Patch appliqué pour : $file"
                    fi
                fi
            fi
        fi
    done < "$CHECKSUM_FILE"

    # Mise à jour des checksums après gestion des conflits
    if [ "$local_changed" -eq 1 ] || [ "$remote_changed" -eq 1 ]; then
        generate_checksums
    fi
}

# Fonction pour synchroniser du cloud vers local
sync_down() {
    rclone sync "$REMOTE_DIR" "$LOCAL_DIR" --fast-list --log-level INFO --config="${CONFIG_PATH}"
    generate_checksums
}

# Fonction pour synchroniser du local vers cloud (avec détection de conflit)
sync_up() {
    check_conflict
    rclone sync "$LOCAL_DIR" "$REMOTE_DIR" --fast-list --log-level INFO --config="${CONFIG_PATH}"
}

boucle1() {
    # Boucle principale
    while true; do
        sync_down
        sleep 10
    done
}

boucle2() {
    while true; do
        inotifywait -r -e modify,create,delete,move  --format '%w%f' "$LOCAL_DIR" | while read file
        do
            sync_up
        done
        echo "$(date) - inotifywait s'est arrêté. Redémarrage..." #| tee -a "$LOG_FILE"
        sleep 2
    done
}

boucle1 &

boucle2