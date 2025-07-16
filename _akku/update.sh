# set -x
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

  # start a download job in bg and record pid
  ( run_wget_job "$url" "$filename" ) &
  local actual_job_pid=$!
  JOB_PIDS["$filename"]=$actual_job_pid
  JOB_STATUS["$filename"]="RUNNING"       # update state
  echo "[helper $filename] job PID: $actual_job_pid"
}

# --- wait a job on fg ---
wait_for_file_foreground() {
  local target_filename="$1"
  local url_for_target="" # init

  echo "checking status. file: '$target_filename'"

  # Find the URL for the target file from the queue initially.
  # This is needed in case we decide to run it foreground.
  local initial_url_found=false
  for i in "${!JOB_QUEUE[@]}"; do
    local entry="${JOB_QUEUE[$i]}"
    local current_url=$(echo "$entry" | cut -d' ' -f1)
    local current_filename=$(echo "$entry" | cut -d' ' -f2)
    if [ "$current_filename" == "$target_filename" ]; then
      url_for_target="$current_url"
      initial_url_found=true
      break
    fi
  done

  # If the file was never queued and has no known status, we can't wait for it.
  if [ "$initial_url_found" == false ] && [[ -z "${JOB_STATUS[$target_filename]}" ]]; then
      echo "[fg job] error: '$target_filename' was never queued and has no known status." >&2
      return 1
  fi


  while true; do
    case "${JOB_STATUS[$target_filename]}" in
      "COMPLETED")
        echo "[fg job '$target_filename'] already downloaded (status: COMPLETED)"
        return 0
        ;;
      "FAILED")
        echo "[fg job '$target_filename'] download failed (status: FAILED)" >&2
        return 1
        ;;
      "RUNNING")
        echo "[fg job '$target_filename'] running. waiting for complete (status: RUNNING)"
        local job_pid="${JOB_PIDS[$target_filename]}"
        if [ -n "$job_pid" ] && kill -0 "$job_pid" 2>/dev/null; then
          if ! wait "$job_pid"; then
            echo "error: PID: $job_pid failed during wait." >&2
            # Mark as failed if wait fails, to prevent infinite loop if job crashes without status update
            JOB_STATUS["$target_filename"]="FAILED"
            return 1
          fi
        else
          # PID not found or process not running. Re-check status, maybe it just completed/failed.
          echo "[fg job '$target_filename'] job PID $job_pid not found or not running. Rechecking status."
          # Loop will re-evaluate status in next iteration
        fi
        ;;
      "QUEUED")
        echo "[fg job '$target_filename'] is queued. Attempting to acquire token for foreground download..."
        if read -n 1 -t 0.01 <&3; then # Try to acquire token non-blockingly first
          echo "[fg job $target_filename] acquired token. Starting foreground download."
          # Claim ownership by updating status and removing from queue
          JOB_STATUS["$target_filename"]="RUNNING"
          # Remove from JOB_QUEUE if it's still there (it should be if status is QUEUED)
          for i in "${!JOB_QUEUE[@]}"; do
            local entry="${JOB_QUEUE[$i]}"
            local current_filename=$(echo "$entry" | cut -d' ' -f2)
            if [ "$current_filename" == "$target_filename" ]; then
              unset 'JOB_QUEUE[i]'
              JOB_QUEUE=("${JOB_QUEUE[@]}") # reindex
              echo "[fg job '$target_filename'] removed from queue for foreground execution."
              break
            fi
          done
          # Now run the job foreground
          run_wget_job "$url_for_target" "$target_filename"
          local exit_code=$?
          echo "[fg job '$target_filename'] foreground download complete."
          return $exit_code # run_wget_job updates status and releases token
        else
          echo "[fg job '$target_filename'] no token available yet. Waiting for dispatcher or free slot."
          # No token, so wait a bit and let dispatcher potentially pick it up
          sleep 0.1
        fi
        ;;
      *)
        # This case handles initial unknown status or stale entries.
        # If it's not in JOB_STATUS, it must be in JOB_QUEUE to be valid.
        # If it's in JOB_QUEUE but not in JOB_STATUS (shouldn't happen if init is correct),
        # or if status is something unexpected.
        echo "[fg job '$target_filename'] unknown status or not yet processed. Checking queue..."
        # Re-verify it's in the queue and set to QUEUED if needed (should be done at init)
        local found_in_queue_for_url=false
        for i in "${!JOB_QUEUE[@]}"; do
          local entry="${JOB_QUEUE[$i]}"
          local current_url=$(echo "$entry" | cut -d' ' -f1)
          local current_filename=$(echo "$entry" | cut -d' ' -f2)
          if [ "$current_filename" == "$target_filename" ]; then
            url_for_target="$current_url" # Ensure URL is set
            JOB_STATUS["$target_filename"]="QUEUED" # Ensure status is QUEUED
            found_in_queue_for_url=true
            break
          fi
        done
        if [ "$found_in_queue_for_url" == false ]; then
          # If it's not in queue and not in JOB_STATUS, it's an error or already handled.
          echo "[fg job] error: '$target_filename' not found in queue and no valid status." >&2
          return 1
        fi
        sleep 0.1 # Wait a bit before next check
        ;;
    esac
    sleep 0.1 # General polling interval for the while loop
  done
}

# --- Dispatcher (blocking, bg) ---
dispatcher() {
  while true; do
    local dispatched_this_loop=0 # Reset for each outer loop iteration

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
        echo "[dispatcher] The queue is empty and all jobs have completed or failed. Stopping."
        break
      fi
      sleep 1
    fi

    for i in "${!JOB_QUEUE[@]}"; do
      local entry="${JOB_QUEUE[$i]}"
      local url=$(echo "$entry" | cut -d' ' -f1)
      local filename=$(echo "$entry" | cut -d' ' -f2)

      # Skip if the state is not QUEUED (it might have been picked up by foreground wait)
      if [[ "${JOB_STATUS[$filename]}" != "QUEUED" ]]; then
        # Remove from queue if its status changed (e.g., picked up by foreground)
        unset 'JOB_QUEUE[i]'
        JOB_QUEUE=("${JOB_QUEUE[@]}") # reindex
        continue # Check next item in the queue
      fi

      # Attempt to acquire a token non-blockingly.
      # If read succeeds, a token is consumed.
      if read -n 1 -t 0.01 <&3; then # Use a very short timeout to make it almost non-blocking
        echo "[dispatcher] acquired a slot. Dispatching new job: ($filename)"
        (issue_download_job "$url" "$filename") & # Run in background
        dispatched_this_loop=$((dispatched_this_loop + 1))
        # Remove the job from queue now that it's dispatched
        unset 'JOB_QUEUE[i]'
        JOB_QUEUE=("${JOB_QUEUE[@]}") # reindex
        break # Dispatched one job, re-evaluate queue from beginning in next outer loop iteration
      else
        # No slot available, break from inner loop and wait
        break
      fi
    done

    # If no jobs were dispatched in this iteration and the queue is not empty,
    # it means all slots are currently occupied.
    if [ "$dispatched_this_loop" -eq 0 ] && [ ${#JOB_QUEUE[@]} -ne 0 ]; then
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
      echo downloading
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
