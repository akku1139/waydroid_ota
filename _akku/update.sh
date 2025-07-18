set -x
set -e

sudo mkdir /mnt/work
sudo chown runner:runner -R /mnt/work

targets=$(find system vendor -type f -name "*.json")


## Download manager

# < 1000 (case [0-9]|[0-9][0-9]|[0-9][0-9][0-9])
MAX_JOBS=15

### Global vars, but they are not shared in subshells.

# key: filename
declare -A FILENAME_URL # value: url
declare -A FILENAME_PID # value: pid

# filename, FIFO
declare -a JOB_QUEUE=()

### End

# init semaphore (and cmd channel)
SEMAPHORE="/run/user/$(id -u)/dl_semaphore_$$"
mkfifo "$SEMAPHORE" || { echo "Error: Couldn't create semaphore"; exit 1; }
exec 3<> "$SEMAPHORE"

for ((i=0; i<MAX_JOBS; i++)); do
  echo "$i" >&3
done

RES_PIPE="/run/user/$(id -u)/dl_res_$$"
mkfifo "$RES_PIPE" || { echo "Error: Couldn't create res pipe"; exit 1; }
exec 4<> "$RES_PIPE"

wget_job() {
  export PS4="% "
  local filename="$1"
  local job_id="$2"
  local url="${FILENAME_URL[$filename]}" # maybe ok
  if [ "$job_id" = "" ]; then
    echo "[job] Start downloading '$filename' from outside the job queue (pid: $$)"
  else
    echo "[job $job_id] Start downloading '$filename' (pid: $$)"
  fi
  wget -nv -O /mnt/work/$filename $url
  echo "d $filename" >&3
  if [ "$job_id" != "" ]; then
    echo "$job_id" >&3 # Return token to the semaphore
  fi
  echo "[job] '$filename' download has been completed (pid: $$)"
}

# main logic. All global variables must be updated here.
dispatcher() {
  export PS4="# "
  local target="$1"
  local job_id
  local cmd
  local filename

  # echo "debug: [dispatcher] show job queue: ${JOB_QUEUE[@]} (target: $target)"
  # echo "debug: [dispatcher] show url list (key): ${!FILENAME_URL[@]} (target: $target)"
  # echo "debug: [dispatcher] show url list (value): ${FILENAME_URL[@]} (target: $target)"
  # echo "debug: [dispatcher] show pid list (key): ${!FILENAME_PID[@]} (target: $target)"
  # echo "debug: [dispatcher] show pid list (value): ${FILENAME_PID[@]} (target: $target)"

  echo "[dispatcher] starting... (target: $target)"
  while true; do
    read cmd <&3

    # echo "debug: [dispatcher] cmd: $cmd"

    case $cmd in
      s)
        echo "[dispatcher] stopping... (target: $target)"
        break
        ;;
      r\ *) # remove from job queue
        filename=$(echo "$cmd" | cut -c 3-)
        echo "[dispatcher] remove '$filename' from the job queue"
        for i in "${!JOB_QUEUE[@]}" ; do
          if [ "${JOB_QUEUE[$i]}" = "$filename" ]; then
            unset JOB_QUEUE[$i]
          fi
        done
        JOB_QUEUE=(${JOB_QUEUE[@]})
        ;;
      d\ *)
        filename=$(echo "$cmd" | cut -c 3-)
        echo "[dispatcher] clean up (file: $filename)"
        unset FILENAME_URL[$filename]
        unset FILENAME_PID[$filename]
        ;;
      p\ *) # get pid
        filename=$(echo "$cmd" | cut -c 3-)
        echo "[dispatcher] get pid of '$filename'"
        echo "${FILENAME_PID[$filename]}" >&4
        ;;
      u\ *) # get url
        filename=$(echo "$cmd" | cut -c 3-)
        echo "[dispatcher] get url of '$filename'"
        echo "${FILENAME_URL[$filename]}" >&4
        ;;
      w\ *) # manual download
        filename=$(echo "$cmd" | cut -c 3-)
        echo "[dispatcher] Starting a manual job (filename: $filename)"

        for i in "${!JOB_QUEUE[@]}" ; do
          if [ "${JOB_QUEUE[$i]}" = "$filename" ]; then
            unset JOB_QUEUE[$i]
          fi
        done
        JOB_QUEUE=(${JOB_QUEUE[@]})

        wget_job "$filename" &
        JOB_PID=$!
        echo "$JOB_PID" >&4
        ;;
      [0-9]|[0-9][0-9]|[0-9][0-9][0-9]) # Numbers up to three digits
        if [ "${#JOB_QUEUE[@]}" -eq 0 ]; then
          echo "[dispatcher] job queue is empty. stopping."
          echo "$cmd" >&3 # Return token to the semaphore
          break
        fi
        local filename="${JOB_QUEUE[0]}"
        # if [ "$filename" = "" ]; then
        #   echo "[dispatcher] All jobs have been run. stopping."
        # fi
        JOB_QUEUE=(${JOB_QUEUE[@]:1})
        job_id="$cmd"
        echo "[dispatcher] Starting a job (id: $job_id)"
        wget_job "$filename" "$job_id" &
        JOB_PID=$!
        FILENAME_PID[$filename]="$JOB_PID"
        ;;
      *)
        echo "[dispatcher] received unknown command '$cmd'"
        ;;
    esac
  done
}

wait_for_file_foreground() {
  local filename="$1"
  local pid=""
  local url=""
  echo "p $filename" >&3
  read pid <&4

  if [ "$pid" = "" ]; then
    echo "u $filename" >&3
    read url <&4
    if [ "$url" = "" ]; then
      echo "[fg] the job is already done (filename: $filename)"
    else
      echo "[fg] the job is waiting (filename: $filename)"
      echo "r $filename" >&3
      echo "[fg] started the job (filename: $filename)"
      read pid <&4
      python _akku/waitpid.py "$pid"
      echo "[fg] the job is complete (filename: $filename)"
    fi
  else
    echo "[fg] the job is running. waiting for completion... (filename: $filename)"
    python _akku/waitpid.py "$pid"
    echo "[fg] the job is complete (filename: $filename)"
  fi
}

## End


for target in $targets; do
  echo "target" $target

  ## Download manager
  FILENAME_URL=()
  FILENAME_PID=()
  JOB_QUEUE=()

  while read -r url filename; do
    [[ "$url" =~ ^#.* ]] && continue
    [ -z "$url" ] && continue

    FILENAME_URL[$filename]="$url"
    JOB_QUEUE+=($filename)
    echo "added a job to queue: $filename"
  done < <(python _akku/files.py "$target")

  echo "job count: ${#JOB_QUEUE[@]}"

  dispatcher "$target" &
  DISPATCHER_PID="$!"
  echo "dispatcher: PID: $DISPATCHER_PID"
  sleep 1
  ## End
  
  cmd="python _akku/save.py $target"

  while true; do
    set +e
    out=($($cmd))
    status="$?"
    set -e

    id="${out[0]}"
    url="${out[1]}"
    filename="${out[2]}"

    bname="dl/$id"

    if [ "$status" -eq 0 ]; then
      echo downloading $filename

      ## select downloader
      # wget -nv -O /mnt/work/$filename $url
      # aria2c -x10 -s10 --console-log-level=warn -o /mnt/work/$filename $url # not working?
      wait_for_file_foreground "$filename"

      echo pushing
      git switch -c "$bname"
      git add -A
      git commit -m "Update"
      chash=$(git rev-parse HEAD)
      git push -u origin $bname

      echo "creating release"
      gh release create "dl-$id" "/mnt/work/$filename" --target "$chash"

      echo merging
      git switch master
      git merge "$bname"
      git push -u origin master
      git branch -d "$bname"
      git push --delete origin "$bname"

      rm "/mnt/work/$filename"

      echo done
    else
      echo "downloading next file..."
      # Stop dispatcher
      echo "s" >&3
      wait "$DISPATCHER_PID"
      sleep 1
      break
    fi
  done

done
