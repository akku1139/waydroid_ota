# set -x
set -e

sudo mkdir /mnt/work
sudo chown runner:runner -R /mnt/work

targets=$(find system vendor -type f -name "*.json")


## Download manager

MAX_JOBS=15

### Global vars, but they are not shared in subshells.

# key: filename
declare -A FILENAME_URL # value: url
declare -A FILENAME_PID # value: pid

# filename, FIFO
declare -a JOB_QUEUE=()

### End

# init semaphore
SEMAPHORE="/run/user/$(id -u)/dl_semaphore_$$"
mkfifo "$SEMAPHORE" || { echo "Error: Couldn't create semaphore"; exit 1; }
exec 3<> "$SEMAPHORE"

for ((i=0; i<MAX_JOBS; i++)); do
  echo "$i" >&3
done

wget_job() {
  local filename="$1"
  local job_id="$2"
  local url="${FILENAME_URL[$filename]}" # maybe ok
  if [ "$job_id" = "" ]; then
    echo "[job] Start downloading '$filename' from outside the job queue (pid: $$)"
  else
    echo "[job $job_id] Start downloading '$filename' (pid: $$)"
  fi
  wget -nv -O /mnt/work/$filename $url
  unset FILENAME_URL[$filename] # FIXME
  unset FILENAME_PID[$filename] # FIXME
  if [ "$job_id" != "" ]; then
    echo "$job_id" >&3 # Return token to the semaphore
  fi
  echo "[job] '$filename' download has been completed (pid: $$)"
}

# main logic. All global variables must be updated here.
dispatcher() {
  local target=$1
  local job_id
  local cmd
  local filename

  echo "[dispatcher] starting... (target: $target)"
  while true; do
    local filename="${JOB_QUEUE[0]}"
    # if [ "$filename" = "" ]; then
    #   echo "[dispatcher] All jobs have been run. stopping."
    # fi
    JOB_QUEUE=(${JOB_QUEUE[@]:1})
    read cmd <&3

    case $cmd in
      s)
        echo "[dispatcher-post] stopping... (target: $target)"
        ;;
      r\ *)
        filename=$(echo "$cmd" | cut -c 3-)
        # remove from the queue
        for i in "${!JOB_QUEUE[@]}" ; do
          if [ "${JOB_QUEUE[$i]}" = "$filename" ]; then
            unset JOB_QUEUE[$i]
          fi
        done
        JOB_QUEUE=(${JOB_QUEUE[@]})
        ;;
      [0-9][0-9]*\ *)
        ;; # ???
      [0-9][0-9]*)
        job_id="$cmd"    
        echo "[dispatcher] Starting a job (id: $job_id)"
        wget_job "$filename" "$job_id" &
        JOB_PID=$!
        FILENAME_PID[$filename]="$JOB_PID"
        ;;
      *)
        echo "[dispatcher-post] received unknown command '$cmd'"
        ;;
    esac
  done
}

wait_for_file_foreground() {
  local filename="$1"
  local pid="${FILENAME_PID[$filename]}" # FIXME
  
  if [ "$pid" = "" ]; then
    if [ "${FILENAME_URL[$filename]}" = "" ]; then
      echo "[fg] the job is already done (filename: $filename)"
    else
      echo "[fg] the job is waiting (filename: $filename)"
      echo "r $filename" >&3
      echo "[fg] started the job (filename: $filename)"
      wget_job "$filename" # TODO; rewrite in dispatcher
      echo "[fg] the job is complete (filename: $filename)"
    fi
  else
    echo "[fg] the job is running. waiting for completion... (filename $filename)"
    wait $pid # FIXME
    echo "[fg] the job is complete (filename: $filename)"
  fi
}

## End


for target in $targets; do
  echo "target" $target

  ## Job manager
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
      wget -nv -O /mnt/work/$filename $url
      # aria2c -x10 -s10 --console-log-level=warn -o /mnt/work/$filename $url # not working?
      # wait_for_file_foreground "$filename"

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
      echo "s" >&3
      break
    fi
  done

done
