#!/usr/bin/env bash

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


rotate_logs_loop() {
    # Exemple de boucle principale avec rotation des logs
    while true; do

        # Gérer le roulement des logs
        rotate_logs "$LOG_FILE"

        # Pause entre deux itérations
        sleep 1
    done
}