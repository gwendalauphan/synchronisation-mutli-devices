# Synchronisation multi-devices

Il nous faut un script qui permet de synchoniser des fichiers en répondant aux besoins suivants:
- synchroniser après modification
- gestion de la non-connection à internet
- gestion des conflits possible


Pour cela, nous allons utiliser:
- inotifywait
	- Surveille les dossiers avec `inotifywait`.
- rclone
	- Synchronise les fichiers modifiés avec `rclone` en utilisant les stratégies définies.
- google drive






Commande pour afficher tous les processus liés au script: (mettre "inotifywa" ou "inotify")
```bash
lsof | grep inotifywa | awk '{print $2}' | while read pid; do
    # Trouver le PGID et le PPID
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    
    # Afficher les informations sur le processus actuel
    echo "=== Processus PID: $pid ==="
    echo "  PGID: $pgid"
    echo "  PPID: $ppid"
    echo
	echo "  Processus liés au PGID $pgid :"
    # Lister tous les processus appartenant au même PGID
    ps -eo pid,pgid,ppid,comm | awk -v pgid="$pgid" '$2 == pgid'
    
    # Afficher une séparation pour les processus
    echo "============================="

done
```

Commande pour supprimer tous les processus liés au script sans tuer le processus parent déclencheur du script: (mettre "inotifywa" ou "inotify")

```bash
lsof | grep inotifywa | grep "/home/gwendalauphan/Documents/Synchronisation-multi-devices" | awk '{print $2}' | while read pid; do
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n "$pgid" ]]; then
        ps -eo pid,pgid,comm | awk -v pgid="$pgid" '$2 == pgid {print $1}' | xargs -r kill -9
    fi
done
```



# Pour créer le service

mkdir -p ~/.config/systemd/user

# init-sync-loqseq.service 

vi ~/.config/systemd/user/init-sync-loqseq.service 

```
[Unit]
Description=Vérification de la connexion au remote Rclone
After=default.target

[Service]
Type=oneshot
ExecStart=/home/gwendalauphan/Documents/Informatique/Projets/Synchronisation-multi-devices/init_sync_logseq.sh
Restart=on-failure
RestartSec=5s
StartLimitInterval=30s
StartLimitBurst=5

[Install]
WantedBy=multi-user.target
```

# sync-loqseq.service 

vi ~/.config/systemd/user/sync-loqseq.service 

```
[Unit]
Description=Synchronisation de fichiers pour Logseq avec inotify et rclone
After=default.target
#OnFailure=serviceFailure (a faire)


[Service]
ExecStart=/home/gwendalauphan/Documents/Informatique/Projets/Synchronisation-multi-devices/sync_logseq.sh
Restart=on-failure
RestartSec=5s
StartLimitInterval=30s
StartLimitBurst=5

[Install]
WantedBy=default.target
```

systemctl --user daemon-reload
systemctl --user enable sync-loqseq.service 
systemctl --user start sync-loqseq.service 
systemctl --user status sync-loqseq.service 


### **Résumé des paramètres**

| Section    | Paramètre       | Description                                                                 |
|------------|-----------------|-----------------------------------------------------------------------------|
| **[Unit]** | `Description`   | Texte décrivant le service.                                                 |
|            | `After`         | Démarre le service après une autre unité (ici `default.target`).            |
| **[Service]** | `ExecStart`     | Commande ou script à exécuter pour démarrer le service.                     |
|            | `Restart`       | Conditions de redémarrage du service (`always`, `on-failure`, etc.).         |
|            | `RestartSec`    | Temps à attendre avant de redémarrer le service après un arrêt.              |
|            | `User`          | Utilisateur sous lequel le service sera exécuté (variable `%u`).            |
| **[Install]** | `WantedBy`      | Cible système ou utilisateur déclenchant le démarrage du service.           |

---


gwendalauphan@gwendalauphan-Latitude-5520:~$ lsof | grep inotify 

gwendalauphan@gwendalauphan-Latitude-5520:~$ ps -eo pid,pgid,comm | grep "172952"
 172952  171398 inotifywait
gwendalauphan@gwendalauphan-Latitude-5520:~$ 
gwendalauphan@gwendalauphan-Latitude-5520:~$ ps -eo pid,pgid,ppid,comm | grep "171398"
 171398  171398  171383 sync_logseq.sh
 172952  171398  171398 inotifywait
 172953  171398  171398 sync_logseq.sh
 174168  171398  171398 sleep

 s -eo pid,pgid,comm | awk -v pgid=171398 '$2 == pgid {print $1}' | xargs kill -9




Penser à faire de connexion à Rclone avant le lancement du script et si erreur qu'il déclenche:
rclone config reconnect GoogleDrivePersoSyncLogseq: --config="/home/gwendalauphan/.config/rclone/rclone.conf" --auto-confirm



    