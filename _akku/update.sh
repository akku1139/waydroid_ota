# set -x
set -e

sudo mkdir /mnt/work
sudo chown runner:runner -R /mnt/work

targets=$(find system vendor -type f -name "*.json")


## Download manager

MAX_JOBS=10

# key: filename
declare -A FILENAME_URL # value: url
declare -A FILENAME_PID # value: pid

# filename, FIFO
declare -a JOB_QUEUE=()

# init semaphore
SEMAPHORE="/run/user/$(id -u)/dl_semaphore_$$"
mkfifo "$SEMAPHORE" || { echo "Error: Couldn't create semaphore"; exit 1; }
exec 3<> "$SEMAPHORE"

for ((i=0; i<MAX_JOBS; i++)); do
  echo "$i" >&3
done

wget_job() {
  filename=$1
  url=${FILENAME_URL[$filename]}
  job_id=$2
  if [ "$job_id" = "" ]; then
    echo "[job] Start downloading '$filename' (from outside the job queue)"
  else
    echo "[job] Start downloading '$filename' (id: $job_id)"
  fi
  wget -nv -O /mnt/work/$filename $url
  unset FILENAME_URL[$filename]
  unset FILENAME_PID[$filename]
  if [ "$job_id" != "" ]; then
    echo "$job_id" >&3 # Return token to the semaphore
  fi
  echo "[job] '$filename' download has been completed"
}

dispatcher() {
  while true; do
    filename=${JOB_QUEUE[0]}
    if [ "$filename" = "" ]; then
      echo "[dispatcher] All jobs have been run. stopping."
      break
    fi
    JOB_QUEUE=${JOB_QUEUE[@]:1}
    read job_id <&3
    echo "[dispatcher] Starting a job (id: $job_id)"
    wget_job $filename $job_id &
    JOB_PID=$!
    FILENAME_PID[$filename]=$JOB_PID
  done
}

wait_for_file_foreground() {
  filename=$1
  pid=${FILENAME_PID[$filename]}
  
  if [ "$pid" = ""]; then
    if [ "${FILENAME_URL[$filename]}" = "" ]; then
      echo "[fg] the job is already done (filename: $filename)"
    else
      echo "[fg] the job is waiting (filename: $filename)"
      # remove from the queue
      for i in "${!JOB_QUEUE[@]}" ; do
        if [ "${JOB_QUEUE[$i]}" = "$filename" ]; then
          unset JOB_QUEUE[$i]
        fi
      done
      JOB_QUEUE=(${JOB_QUEUE[@]})
      echo "[fg] started the job (filename: $filename)"
      wget_job $filename
      echo "[fg] the job is complete (filename: $filename)"
    fi
  else
    echo "[fg] the job is running. waiting for completion... (filename $filename)"
    wait $pid
    echo "[fg] the job is complete (filename: $filename)"
  fi
}

## End


for target in $targets; do
  echo "target" $target

  while read -r url filename; do
    [[ "$url" =~ ^#.* ]] && continue
    [ -z "$url" ] && continue

    FILENAME_URL[$filename]=$url
    JOB_QUEUE+=($filename)
    echo "added a job to queue: $filename"
  done < <(python _akku/files.py $target)

  echo "job count: ${#JOB_QUEUE[@]}"

  dispatcher &
  DISPATCHER_PID=$!
  echo "dispatcher: PID: $DISPATCHER_PID"
  sleep 2
  
  cmd="python _akku/save.py $target"

  while true; do
    set +e
    out=($($cmd))
    status=$?
    set -e

    id=${out[0]}
    url=${out[1]}
    filename=${out[2]}

    bname="dl/$id"

    if [ "$status" -eq 0 ]; then
      echo downloading $filename
      # wget -nv -O /mnt/work/$filename $url
      # aria2c -x10 -s10 --console-log-level=warn -o /mnt/work/$filename $url
      wait_for_file_foreground $filename

      echo pushing
      git switch -c $bname
      git add -A
      git commit -m "Update"
      chash=$(git rev-parse HEAD)
      git push -u origin $bname

      echo "creating release"
      gh release create dl-$id "/mnt/work/$filename" --target $chash

      echo merging
      git switch master
      git merge $bname
      git push -u origin master
      git branch -d $bname
      git push --delete origin $bname

      rm /mnt/work/$filename

      echo done
    else
      echo "downloading next file..."
      break
    fi
  done

done
