#!/bin/bash

set -e  # Arrêter l'exécution en cas d'erreur

# Vérifier si Conda est installé
if ! command -v conda &> /dev/null; then
    echo "Conda n'est pas installé. Installe Miniconda ou Anaconda avant d'exécuter ce script."
    exit 1
fi

# Détermine le chemin absolu du répertoire du script
PROJECT_DIR=$(dirname "$(realpath "$0")")
CONFIG_DIR="$PROJECT_DIR/config"
JINJA_DIR="$PROJECT_DIR/jinja"
SCRIPT_DIR="$PROJECT_DIR/scripts"

source "$CONFIG_DIR/config.env"

# Créer et activer l'environnement Conda
ENV_NAME="sync-logseq-service"

echo "Création de l'environnement Conda '$ENV_NAME' avec Python 3.12..."
conda create -y -n "$ENV_NAME" python=3.12 &> /dev/null

echo "Activation de l'environnement Conda..."
source $(conda info --base)/etc/profile.d/conda.sh
conda activate "$ENV_NAME"

# Installer Jinja2
echo "Installation de Jinja2 et dotenv..."
pip install jinja2 python-dotenv &> /dev/null

# Créer le dossier Systemd pour l'utilisateur
mkdir -p "$SYSTEMD_USER_DIR"
echo "Dossier Systemd créé : $SYSTEMD_USER_DIR"

# Exécuter le script Python pour générer le fichier de service
echo "Génération des services Systemd..."
python generate_service.py $JINJA_DIR/$INIT_SYNC_LOGSEQ_SERIVCE_JINJA_FILE $SYSTEMD_USER_DIR $SCRIPT_DIR
python generate_service.py $JINJA_DIR/$SYNC_LOGSEQ_SERVICE_JINJA_FILE $SYSTEMD_USER_DIR $SCRIPT_DIR

conda deactivate
conda env remove -n "$ENV_NAME" -y &> /dev/null

# Recharger Systemd et activer le service
echo "Rechargement de Systemd..."
systemctl --user daemon-reload

echo "Activation du service..."
systemctl --user enable sync-logseq.service

echo "Démarrage du service..."
systemctl --user restart sync-logseq.service


echo "Installation et lancement du service terminés avec succès."


