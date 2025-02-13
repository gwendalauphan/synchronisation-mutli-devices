#!/bin/bash

#set -euo pipefail  #S'assure de la robustesse du script

# Définition du répertoire temporaire
#TMP_DIR=$(mktemp -d)
TMP_DIR="/tmp"
TEXT_DIR="$TMP_DIR/texts"
PATCH_DIR="$TMP_DIR/patches"
#rm -rf "$PATCH_DIR"
rm -rf "$TEXT_DIR"
mkdir -p "$PATCH_DIR"
mkdir -p "$TEXT_DIR"



merge_files() {
    local file1="$1"
    local file2="$2"
    local filename="$3"

    echo "Fusion ligne par ligne en cours pour $file2 ..."

    #--------------------------------------------------------------------------
    # 1) Lecture + "normalisation" (trim) des lignes pour gérer les espaces
    #--------------------------------------------------------------------------
    # La fonction trim() supprime les espaces (blancs) en début et fin de ligne.
    # Si vous NE VOULEZ PAS ignorer les espaces, retirez la partie "normalize".
    normalize() {
        sed -e 's/^[[:space:]]*//;s/[[:space:]]*$//'
    }

    # On lit chaque fichier, en "nettoyant" les espaces en début/fin de ligne.
    mapfile -t arr1 < <(normalize < "$file1")
    mapfile -t arr2 < <(normalize < "$file2")

    local len1=${#arr1[@]}
    local len2=${#arr2[@]}
    local i=0
    local j=0

    #--------------------------------------------------------------------------
    # 2) Fonction utilitaire pour afficher un bloc conflictuel
    #--------------------------------------------------------------------------
    conflict_block() {
        local start1="$1"
        local end1="$2"
        local start2="$3"
        local end2="$4"

        echo "<<<<<<<<<<<<<"
        for (( k = start1; k < end1; k++ )); do
            echo "${arr1[$k]}"
        done
        echo ">>>>>>>>>>>>>"
        for (( k = start2; k < end2; k++ )); do
            echo "${arr2[$k]}"
        done
        echo ""
    }

    {
        #--------------------------------------------------------------------------
        # 3) Boucle principale : avancement parallèle avec resynchronisation
        #--------------------------------------------------------------------------
        while [[ $i -lt $len1 && $j -lt $len2 ]]; do

            if [[ "${arr1[$i]}" == "${arr2[$j]}" ]]; then
                #
                # 3.1) Lignes identiques => on les affiche directement
                #
                echo "${arr1[$i]}"
                ((i++))
                ((j++))

            else
                #
                # 3.2) Différence => on cherche la prochaine ligne commune "plus loin"
                #
                local foundCommon=false
                local i2=-1
                local j2=-1

                # Recherche brute de la prochaine ligne commune :
                for (( x = i; x < len1; x++ )); do
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
                    # On crée un bloc de conflit pour les segments divergents
                    conflict_block "$i" "$i2" "$j" "$j2"
                    # Puis on se recale sur la ligne commune trouvée
                    i=$i2
                    j=$j2
                else
                    # Aucune ligne commune jusqu'à la fin => tout le reste est conflit
                    conflict_block "$i" "$len1" "$j" "$len2"
                    i=$len1
                    j=$len2
                fi
            fi
        done

        #--------------------------------------------------------------------------
        # 4) Lignes restantes (si un fichier est plus long que l'autre)
        #--------------------------------------------------------------------------
        if [[ $i -lt $len1 || $j -lt $len2 ]]; then
            # On décide ici de tout mettre dans un dernier bloc conflictuel,
            # car il n'y a plus de "ligne commune" possible pour se resynchroniser.
            conflict_block "$i" "$len1" "$j" "$len2"
        fi

    } > "$TMP_DIR/$filename.tmp"

    mv "$TMP_DIR/$filename.tmp" "$file2"
    echo "Fusion avec marquage effectuée pour $file2"

    # Vérification après la fusion
    echo "Contenu de file2.txt après fusion :"
    cat "$file2"
}






# Création de fichiers de test
echo "Ligne 1 commun" > "$TEXT_DIR/file1.txt"
echo " " >> "$TEXT_DIR/file1.txt"
echo "Ligne 2 text 1" >> "$TEXT_DIR/file1.txt"
echo " " >> "$TEXT_DIR/file2.txt"
echo "Ligne 3 commun" >> "$TEXT_DIR/file1.txt"
echo "Ligne 4 text 1" >> "$TEXT_DIR/file1.txt"
echo " " >> "$TEXT_DIR/file2.txt"
echo "Ligne 6 commun" >> "$TEXT_DIR/file1.txt"

echo "Ligne 1 commun" > "$TEXT_DIR/file2.txt"
echo "Ligne 2 text 2" >> "$TEXT_DIR/file2.txt"
echo " " >> "$TEXT_DIR/file2.txt"
echo "Ligne 2,5 text 2" >> "$TEXT_DIR/file2.txt"
echo "Ligne 3 commun" >> "$TEXT_DIR/file2.txt"
echo "Ligne 4 text 2" >> "$TEXT_DIR/file2.txt"
echo "Ligne 5 text 2" >> "$TEXT_DIR/file2.txt"
echo "Ligne 6 commun" >> "$TEXT_DIR/file2.txt"


echo "Fichiers créés :"
echo "file1.txt :"
cat "$TEXT_DIR/file1.txt"
echo "file2.txt :"
cat "$TEXT_DIR/file2.txt"

# Appel de la fonction pour tester la fusion
merge_files "$TEXT_DIR/file2.txt" "$TEXT_DIR/file1.txt"  "test_merge"








