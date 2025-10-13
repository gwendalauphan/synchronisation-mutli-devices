#!/bin/bash

set -e  # Arrêter l'exécution en cas d'erreur

# Détermine le chemin absolu du répertoire du script
PROJECT_DIR=$(dirname "$(realpath "$0")")
CONFIG_DIR="$PROJECT_DIR/config"
JINJA_DIR="$PROJECT_DIR/jinja"
SCRIPT_DIR="$PROJECT_DIR/scripts"

source "$CONFIG_DIR/config.env"

# Créer et activer l'environnement virtuel Python
ENV_DIR="$PROJECT_DIR/.venv"

echo "Création de l'environnement virtuel Python dans '$ENV_DIR'..."
python3 -m venv "$ENV_DIR"

echo "Activation de l'environnement virtuel..."
source "$ENV_DIR/bin/activate"

# Installer Jinja2
echo "Installation de Jinja2 et dotenv..."
pip install --upgrade pip &> /dev/null
pip install jinja2 python-dotenv &> /dev/null

# Créer le dossier Systemd pour l'utilisateur
mkdir -p "$SYSTEMD_USER_DIR"
echo "Dossier Systemd créé : $SYSTEMD_USER_DIR"

# Exécuter le script Python pour générer le fichier de service
echo "Génération des services Systemd..."
python generate_service.py $JINJA_DIR/$INIT_SYNC_LOGSEQ_SERIVCE_JINJA_FILE $SYSTEMD_USER_DIR $SCRIPT_DIR
python generate_service.py $JINJA_DIR/$SYNC_LOGSEQ_SERVICE_JINJA_FILE $SYSTEMD_USER_DIR $SCRIPT_DIR

deactivate

# Supprimer le dossier de l'environnement virtuel
rm -rf "$ENV_DIR"

# Recharger Systemd et activer le service
echo "Rechargement de Systemd..."
systemctl --user daemon-reload

echo "Activation du service..."
systemctl --user enable sync-logseq.service

echo "Démarrage du service..."
systemctl --user restart sync-logseq.service

echo "Installation et lancement du service terminés avec succès."


