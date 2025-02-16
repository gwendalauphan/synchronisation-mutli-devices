import sys
import os
from jinja2 import Template
from dotenv import load_dotenv

# Vérification des arguments
if len(sys.argv) != 4:
    print("Usage: python generate_service.py <template_file> <output_directory> <script_directory>")
    sys.exit(1)

template_file = sys.argv[1]
output_directory = sys.argv[2]
script_directory = sys.argv[3]

# Charger les variables d'environnement depuis config/config.env
load_dotenv(dotenv_path="config/config.env")

# Vérifier si le fichier template existe
if not os.path.isfile(template_file):
    print(f"Erreur : le fichier template '{template_file}' n'existe pas.")
    sys.exit(1)

# Lire le fichier template
with open(template_file, 'r') as file:
    template_content = file.read()

# Charger le template Jinja
template = Template(template_content)

# Définir les variables d'environnement pour le rendu
# Définir les variables d'environnement pour le rendu
context = {
    "init_sync_script_path": script_directory + "/" + os.getenv("INIT_SYNC_SCRIPT_NAME"),
    "init_sync_restart_sec": os.getenv("INIT_SYNC_RESTART_SEC"),
    "init_sync_start_limit_interval": os.getenv("INIT_SYNC_START_LIMIT_INTERVAL"),
    "init_sync_start_limit_burst": os.getenv("INIT_SYNC_START_LIMIT_BURST"),
    "sync_script_path": script_directory + "/" + os.getenv("SYNC_SCRIPT_NAME"),
    "sync_restart_sec": os.getenv("SYNC_RESTART_SEC"),
    "sync_start_limit_interval": os.getenv("SYNC_START_LIMIT_INTERVAL"),
    "sync_start_limit_burst": os.getenv("SYNC_START_LIMIT_BURST"),
}

# Rendre le template
service_content = template.render(context)

# Déterminer le nom de sortie
output_file = os.path.join(output_directory, os.path.basename(template_file).replace(".jinja", ""))

# Sauvegarder le fichier généré
with open(output_file, "w") as output:
    output.write(service_content)

print(f"Service Systemd généré : {output_file}")
