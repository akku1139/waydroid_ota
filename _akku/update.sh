set -x
set -e

sudo mkdir /mnt/work
sudo chown runner:runner -R /mnt/work

targets=$(find system vendor -type f -name "*.json")


## Download manager (Based on Gemini 2.5 Flash)

MAX_JOBS=10

SEMAPHORE="/run/user/$(id -u)/dl_semaphore_$$"

# key: filename, value: "QUEUED", "RUNNING", "COMPLETED", "FAILED"
declare -A JOB_STATUS

declare -A JOB_PIDS
declare -a JOB_QUEUE=()

# --- init semaphore ---
mkfifo "$SEMAPHORE" || { echo "Error: Couldn't create semaphore"; exit 1; }
# Assign fd 3 to a named pipe for both read and write
exec 3<> "$SEMAPHORE"

for ((i=0; i<MAX_JOBS; i++)); do
  echo "" >&3
done
echo "The semaphore has been initialized. Available slots: $MAX_JOBS"

# cleanup
# trap "rm -f '$SEMAPHORE'; exec 3>&-; echo 'job queue is cleanuped'; jobs -p | xargs -r kill 2>/dev/null" EXIT

# --- download worker ---
# 1. run wget
# 2. update job status
# 3. release token
run_wget_job() {
  local url="$1"
  local filename="$2"

  echo "[job $filename] starting download. PID: $$"
  wget -nv -O "/mnt/work/$filename" "$url"
  local exit_code=$?

  if [ $exit_code -eq 0 ]; then
    echo "[job $filename] download complete"
    JOB_STATUS["$filename"]="COMPLETED"
  else
    echo "[job $filename] download failed. error code: $exit_code" >&2
    JOB_STATUS["$filename"]="FAILED"
  fi
  echo "" >&3 # return token
}

# --- issue job (bg) ---
# issue new job
# skip jobs that are already running or completed
# get a token from semaphore and then start the actual download job in the background
issue_download_job() {
  local url="$1"
  local filename="$2"

  # check the job is already running or completed
  if [[ "${JOB_STATUS[$filename]}" == "RUNNING" || "${JOB_STATUS[$filename]}" == "COMPLETED" ]]; then
    echo "[helper $filename] the job is already running or completed. skip."
    return 0
  fi

  echo "[helper $filename] trying to get a slot..."
  read -n 1 <&3 # get token (blocking)
  echo "[helper $filename] starting download"

  # start a download job in bg and record pid
  ( run_wget_job "$url" "$filename" ) &
  local actual_job_pid=$!
  JOB_PIDS["$filename"]=$actual_job_pid
  JOB_STATUS["$filename"]="RUNNING"     # update state
  echo "[helper $filename] job PID: $actual_job_pid"
}

# --- wait a job on fg ---
wait_for_file_foreground() {
  local target_filename="$1"
  local url_for_target="" # init

  echo "checking status. file: '$target_filename'"

  # find the target job from the queue, execute it if it exists, and wait for it to complete
  local found_in_queue=false
  for i in "${!JOB_QUEUE[@]}"; do
    local entry="${JOB_QUEUE[$i]}"
    local current_url=$(echo "$entry" | cut -d' ' -f1)
    local current_filename=$(echo "$entry" | cut -d' ' -f2)

    if [ "$current_filename" == "$target_filename" ]; then
      url_for_target="$current_url"
      found_in_queue=true
      
      # remove from queue (効率は良くないが、Bash配列ではこれが一般的)
      unset 'JOB_QUEUE[i]'
      JOB_QUEUE=("${JOB_QUEUE[@]}") # reindex
      echo "[fg job '$target_filename'] removed from queue."
      break
    fi
  done

  if [[ "${JOB_STATUS[$target_filename]}" == "COMPLETED" ]]; then
    echo "[fg job '$target_filename'] already downloaded"
    return 0
  elif [[ "${JOB_STATUS[$target_filename]}" == "RUNNING" ]]; then
    echo "[fg job '$target_filename'] running. waiting for complete"
    local job_pid="${JOB_PIDS[$target_filename]}"
    if ! wait "$job_pid"; then
      echo "error: PID: $job_pid"
      return 1
    fi
  elif [ "$found_in_queue" == true ]; then
    echo "[fg job '$target_filename'] started job"
    
    # get token
    echo "[fg job $target_filename] trying to get token..."
    read -n 1 <&3
    echo "[fg job $target_filename] starting download"

    # Start the actual download job in the fg and wait for it to complete
    run_wget_job "$url_for_target" "$target_filename"
    # semaphore token will be automatically released
    echo "[fg job '$target_filename'] download complete"
    return 0
  else
    echo "[fg job] error: couldn't find a job for '$target_filename'."
    return 1
  fi

  echo "[jg job '$target_filename'] download done"
  return 0
}

# --- Dispatcher (blocking, bg) ---
dispatcher() {
  while true; do
    # Loop until the queue is empty or there are no more jobs available to run
    if [ ${#JOB_QUEUE[@]} -eq 0 ]; then
      # Stop dispatcher if all jobs are queued and all completed or failed
      local all_done_check=true
      for status in "${JOB_STATUS[@]}"; do
        if [[ "$status" == "QUEUED" || "$status" == "RUNNING" ]]; then
          all_done_check=false
          break
        fi
      done
      if [ "$all_done_check" == true ]; then
        echo "[dispatcher] The queue is empty and all jobs have completed or failed. stopping."
        break
      fi
      echo "[dispatcher] The queue is empty, but there are unfinished jobs. waiting..."
      sleep 1
    fi

    local dispatched_count=0
    for i in "${!JOB_QUEUE[@]}"; do
      local entry="${JOB_QUEUE[$i]}"
      local url=$(echo "$entry" | cut -d' ' -f1)
      local filename=$(echo "$entry" | cut -d' ' -f2)

      # Skip if the state is not QUEUED
      if [[ "${JOB_STATUS[$filename]}" != "QUEUED" ]]; then
        continue
      fi

      # Check if slots are available（non-blocking）
      if read -n 1 -t 0 <&3; then # get token
        echo "" >&3 # return token
        echo "[dispatcher] dispatch a new job: ($filename)"
        (issue_download_job "$url" "$filename") &
        # remove the job from queue
        unset 'JOB_QUEUE[i]'
        dispatched_count=$((dispatched_count + 1))
      else
        break
      fi
    done
    
    # reindex
    JOB_QUEUE=("${JOB_QUEUE[@]}") 

    if [ "$dispatched_count" -eq 0 ] && [ ${#JOB_QUEUE[@]} -ne 0 ]; then
      # echo "[dispatcher] Cannot dispatch new jobs because slots are filled. waiting..."
      sleep 1
    fi

    sleep 0.1 # Polling Interval
  done
}

## End


for target in $targets; do
  echo "target" $target

  while read -r url filename; do
    [[ "$url" =~ ^#.* ]] && continue
    [ -z "$url" ] && continue
  
    JOB_QUEUE+=("$url $filename") # enqueue
    JOB_STATUS["$filename"]="QUEUED" # init job status
    echo "added a job to queue: $filename"
  done < <(python _akku/files.sh $target)

  echo "job count: ${#JOB_QUEUE[@]}"

  dispatcher &
  DISPATCHER_PID=$!
  echo "dispatcher: PID: $DISPATCHER_PID"
  
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
      # wget -nv -O /mnt/work/$filename $url
      # aria2c -x10 -s10 --console-log-level=warn -o /mnt/work/$filename $url
      wait_for_file_foreground $filename

      git switch -c $bname
      git add -A
      git commit -m "Update"
      chash=$(git rev-parse HEAD)
      git push -u origin $bname

      gh release create dl-$id "/mnt/work/$filename" --target $chash

      git switch master
      git merge $bname
      git push -u origin master
      git branch -d $bname
      git push --delete origin $bname

      rm /mnt/work/$filename
    else
      echo "downloading next file..."
      break
    fi
  done

done
