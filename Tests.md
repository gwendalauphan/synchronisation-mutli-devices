

# SCENARIO GLOBAL 1

# - - - - Contexte initial (t1) - - - - #

En local
	file1.txt
	file2.txt
	file3.txt

En remote
	file1.txt
	file2.txt
	file3.txt

À ce stade, les deux répertoires (local et remote) sont identiques.

# - - - - Étape t2 : Modifications sur le remote - - - - #

En remote
	file1.txt (modifié)
	file2.txt (supprimé)
	file3.txt (supprimé)
	file4.txt (créé)

Objectif de test : Vérifier la suppression côté remote et la stabilité côté local


# - - - - Étape t3 : Modifications sur le local - - - - #

En local
	file1.txt (modifié localement)
	file2.txt (toujours présent)
	file3.txt (modifié localement)
	file5.txt (créé localement)

Objectif de test : Vérifier les modifications côté local et la stabilité côté remote


# - - - - Étape t4 : Merge en local et copie vers le remote - - - - #

L’exemple décrit une situation de merge
    file1.txt a été modifié des deux côtés (remote et local).
    file2.txt : supprimé en remote.
    file3.txt : supprimé en remote mais modifié en local.
    file5.txt : créé localement.

En local, après un merge Remote -> Local, on obtient :
    file1.txt (version mergeant les deux modifications : fusionner les modifications)
    file2.txt → (toujours présent car il s'agit d'un merge et non d'un sync).
    file3.txt → gardé et mis à jour, car le remote l’a supprimé, mais on a une modification locale.
    file5.txt → conservé, car il est nouveau localement.

Objectif de test en local: 
	- Vérifier le contenu file1
	- Vérifier la présence file2
	- Vérifier la présence et contenu file3
	- Vérifier la présence file5


Ensuite en remote, après un merge Local -> Remote, on obtient :
    file1.txt est uploadé dans sa version merged.
    file3.txt est recréé ou mis à jour en remote (puisqu’il était supprimé en remote mais modifié en local).
    file5.txt est créé en remote.
    file2.txt n’est pas recréé en remote car on suit la suppression effectuée en remote.

Objectif de test en remote : 
	- Vérifier le contenu file1
	- Vérifier la présence et contenu file3
	- Vérifier la présence file4
	- Vérifier la présence file5

# - - - - Étape t5 : Synchronisation de remote vers local - - - - #

Après la mise à jour côté remote, il faut rapatrier les derniers changements en local, au cas où on aurait un delta.
Sync Remote -> Local

En remote, on a désormais :
	file1.txt (version merged)
	file3.txt
	file4.txt
	file5.txt

La synchronisation remote → local confirme que les deux côtés sont bien à jour :
	file1.txt (merged)
	file3.txt
	file4.txt (créé côté remote au t2, donc on le récupère)
	file5.txt (modifé côté local au t3, mais maintenant présent également en remote)

Objectif de test en local : 
	- Vérifier le contenu file1
	- Vérifier la suppression file2
	- Vérifier la présence et contenu file3
	- Vérifier la présence file4
	- Vérifier la présence file5



# SCENARIO GLOBAL 2

# Setup initial

- Création de deux fichiers fileA.txt et fileB.txt identiques dans 
- LOCAL_DIR et REMOTE_DIR.

# Étape 2

- Modification locale de fileA.txt.
- On simule l’appel à on_change() (qui serait déclenché par inotifywait) pour synchroniser vers le remote.
- On vérifie que fileA.txt est bien mis à jour côté remote.

# Étape 3 : Conflit sur fileB.txt

- fileB.txt est modifié en local.
- Presque en même temps, fileB.txt est modifié côté remote.
- À la détection côté local (on_change()), on compare local ↔ remote et on s’aperçoit qu’ils sont tous les deux modifiés → conflit.
- handle_conflicts() se charge de faire un merge. Dans l’exemple, on concatène simplement “Local version B” + “Remote version B”, puis on alimente local et remote.





# SCENARIO GLOBAL 3 - A éditer

# Setup initial




# SCENARIO GLOBAL 4 - A Créer (Celui sur le fait d'avoir un fichier créé en local, et le cloud qui n'a pas bougé)

# Setup initial


# Autres cas possibles à tester

Coupure réseau en cours de synchronisation
	Lancer une modification locale/remote, couper la connexion en plein transfert, puis la rétablir.
	Vérifier que la synchronisation reprend correctement et gère les conflits si de nouvelles modifications ont été faites pendant la coupure.

Modification simultanée sur plusieurs fichiers
	Plusieurs fichiers modifiés en même temps côté local et/ou remote.
	Vérifier la gestion des verrous (une seule synchronisation à la fois) et l’ordre des opérations.

Suppression locale d’un fichier qui a aussi été supprimé en remote
	Vérifier la détection de la suppression redondante et l’absence de conflits.
