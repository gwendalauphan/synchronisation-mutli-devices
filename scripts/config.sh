PGID=$(ps -o pgid= $$ | grep -o '[0-9]*')

# Variable pour éviter les appels multiples à cleanup
CLEANUP_DONE=0

# Fichiers pour synchronisation
FILES_TO_SYNC="$TMP_DIR/cloud_files.txt"
LOCK_FILE="$TMP_DIR/sync.lock"
PATCH_DIR="$TMP_DIR/patches"

# PID du processus `inotifywait`
INOTIFY_PID_FILE="$TMP_DIR/inotify.pid"
INOTIFY_LOOP_FILE="$TMP_DIR/inotify.loop"
LOCK_ATTEMPTS_FILE="$TMP_DIR/lock_attempts"
LOCK_ATTEMPTS_REMOTE_FILE="$TMP_DIR/lock_attempts_remote"

# Fichiers de checksums
CHECKSUM_FILE_REMOTE_PREVIOUS="$CHECKSUM_DIR/checksums_remote_previous.txt"
CHECKSUM_FILE_REMOTE_CURRENT="$CHECKSUM_DIR/checksums_remote_current.txt"
CHECKSUM_FILE_LOCAL_CURRENT="$CHECKSUM_DIR/checksums_local_current.txt"

# Fichier de log
LOG_FILE="$LOG_DIR/sync.log"

