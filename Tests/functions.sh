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