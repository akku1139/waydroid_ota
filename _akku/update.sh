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
declare -a JOB_QUEUE=() # Stores "url filename" entries

# --- init semaphore ---
# Create a named pipe (FIFO) to act as a semaphore.
# Each empty string written to it represents an available slot.
mkfifo "$SEMAPHORE" || { echo "Error: Couldn't create semaphore"; exit 1; }
# Assign file descriptor 3 to the named pipe for both read and write.
# This allows processes to acquire (read) and release (write) tokens.
exec 3<> "$SEMAPHORE"

# Initialize the semaphore with MAX_JOBS tokens.
for ((i=0; i<MAX_JOBS; i++)); do
  echo "" >&3
done
echo "The semaphore has been initialized. Available slots: $MAX_JOBS"

# Note: Cleanup (trap) is omitted as per user's request for CI environment.

# --- download worker ---
# This function performs the actual download using wget.
# It updates the job's status and releases a semaphore token upon completion (success or failure).
# Arguments:
#   $1: URL of the file to download
#   $2: Target filename (base name, not full path)
run_wget_job() {
  local url="$1"
  local filename="$2"

  echo "[job $filename] starting download. PID: $$"
  # -nv: no verbose output
  # -O: output document to specified file
  wget -nv -O "/mnt/work/$filename" "$url"
  local exit_code=$?

  if [ $exit_code -eq 0 ]; then
    echo "[job $filename] download complete"
    JOB_STATUS["$filename"]="COMPLETED"
  else
    echo "[job $filename] download failed. error code: $exit_code" >&2
    JOB_STATUS["$filename"]="FAILED"
  fi
  echo "" >&3 # Return token to the semaphore
}

# --- issue job (background) ---
# This function starts a download job in the background.
# It records the PID and immediately updates the job status to "RUNNING".
# Arguments:
#   $1: URL of the file
#   $2: Target filename
issue_download_job() {
  local url="$1"
  local filename="$2"

  # Run run_wget_job in a subshell in the background.
  ( run_wget_job "$url" "$filename" ) &
  local actual_job_pid=$!
  JOB_PIDS["$filename"]=$actual_job_pid
  JOB_STATUS["$filename"]="RUNNING" # Update state to RUNNING
  echo "[helper $filename] job PID: $actual_job_pid"
}

# --- wait a job on foreground ---
# This function waits for a specific file to complete its download.
# If the file is QUEUED, it attempts to acquire a semaphore token and run the download in the foreground.
# If the file is RUNNING, it waits for the background process to finish.
# Arguments:
#   $1: Target filename to wait for
wait_for_file_foreground() {
  local target_filename="$1"
  local url_for_target="" # Initialize variable to store the URL

  echo "checking status. file: '$target_filename'"

  # First, try to find the URL for the target file from the JOB_QUEUE.
  # This is necessary in case the job is still QUEUED and needs to be run foreground.
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

  # If the file was never queued and has no known status, it's an error.
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
        # Check if the process still exists and is running.
        if [ -n "$job_pid" ] && kill -0 "$job_pid" 2>/dev/null; then
          # Wait for the specific background job to finish.
          if ! wait "$job_pid"; then
            echo "error: PID: $job_pid failed during wait." >&2
            # Mark as failed if wait fails, to prevent infinite loop if job crashes without status update.
            JOB_STATUS["$target_filename"]="FAILED"
            return 1
          fi
        else
          # PID not found or process not running. Re-check status, maybe it just completed/failed.
          echo "[fg job '$target_filename'] job PID $job_pid not found or not running. Rechecking status."
          # Loop will re-evaluate status in next iteration.
        fi
        ;;
      "QUEUED")
        # The job is queued. Attempt to acquire a token to run it in the foreground.
        # Use a very short timeout (0.01 seconds) to make it almost non-blocking.
        if read -n 1 -t 0.01 <&3; then
          echo "[fg job $target_filename] acquired token. Starting foreground download."

          # IMPORTANT: Claim ownership immediately by updating status and removing from queue.
          # This prevents the dispatcher from trying to pick up the same job concurrently.
          JOB_STATUS["$target_filename"]="RUNNING"
          # Remove the job from JOB_QUEUE.
          for i in "${!JOB_QUEUE[@]}"; do
            local entry="${JOB_QUEUE[$i]}"
            local current_filename=$(echo "$entry" | cut -d' ' -f2)
            if [ "$current_filename" == "$target_filename" ]; then
              unset 'JOB_QUEUE[i]'
              JOB_QUEUE=("${JOB_QUEUE[@]}") # Reindex the array after unsetting.
              echo "[fg job '$target_filename'] removed from queue for foreground execution."
              break
            fi
          done

          # Now run the download job in the foreground.
          run_wget_job "$url_for_target" "$target_filename"
          local exit_code=$?
          echo "[fg job '$target_filename'] foreground download complete."
          return $exit_code # run_wget_job already updates status and releases token.
        else
          # No token available yet. Wait a bit and let the dispatcher potentially pick it up.
          sleep 0.1
        fi
        ;;
      *)
        # This case handles initial unknown status or stale entries.
        # If it's not in JOB_STATUS, it must be in JOB_QUEUE to be valid.
        echo "[fg job '$target_filename'] unknown status or not yet processed. Checking queue..."
        # Re-verify it's in the queue and set to QUEUED if needed (should be done at init).
        local found_in_queue_for_url_recheck=false
        for i in "${!JOB_QUEUE[@]}"; do
          local entry="${JOB_QUEUE[$i]}"
          local current_url=$(echo "$entry" | cut -d' ' -f1)
          local current_filename=$(echo "$entry" | cut -d' ' -f2)
          if [ "$current_filename" == "$target_filename" ]; then
            url_for_target="$current_url" # Ensure URL is set.
            JOB_STATUS["$target_filename"]="QUEUED" # Ensure status is QUEUED.
            found_in_queue_for_url_recheck=true
            break
          fi
        done
        if [ "$found_in_queue_for_url_recheck" == false ]; then
          # If it's not in queue and not in JOB_STATUS, it's an error or already handled.
          echo "[fg job] error: '$target_filename' not found in queue and no valid status." >&2
          return 1
        fi
        sleep 0.1 # Wait a bit before next check.
        ;;
    esac
    sleep 0.1 # General polling interval for the while loop.
  done
}

# --- Dispatcher (background process) ---
# This function continuously monitors the JOB_QUEUE and dispatches jobs to background workers
# as semaphore tokens become available.
dispatcher() {
  while true; do
    local dispatched_this_loop=0 # Counter for jobs dispatched in the current iteration.

    # Get current indices of the JOB_QUEUE to iterate safely,
    # as elements might be unset during the loop by foreground waits.
    local current_queue_indices=("${!JOB_QUEUE[@]}")
    for i in "${current_queue_indices[@]}"; do
      local entry="${JOB_QUEUE[$i]}"
      # Skip if the entry has already been unset (e.g., picked up by foreground wait).
      if [ -z "$entry" ]; then
        continue
      fi

      local url=$(echo "$entry" | cut -d' ' -f1)
      local filename=$(echo "$entry" | cut -d' ' -f2)

      # Check the current status of the job.
      # If it's not QUEUED (meaning it's RUNNING, COMPLETED, or FAILED),
      # remove it from the dispatcher's queue and continue.
      if [[ "${JOB_STATUS[$filename]}" != "QUEUED" ]]; then
        unset 'JOB_QUEUE[i]'
        continue # Check next item in the queue.
      fi

      # Attempt to acquire a token non-blockingly.
      if read -n 1 -t 0.01 <&3; then # Use a very short timeout.
        echo "[dispatcher] acquired a slot. Dispatching new job: ($filename)"
        # Dispatch the job in the background. issue_download_job will update status to RUNNING.
        (issue_download_job "$url" "$filename") &
        dispatched_this_loop=$((dispatched_this_loop + 1))
        # Remove the job from the queue now that it's dispatched.
        unset 'JOB_QUEUE[i]'
        # Continue to try and dispatch more jobs if slots are available.
      else
        # No slot available, break from inner loop and wait for a slot to free up.
        break
      fi
    done

    # Reindex JOB_QUEUE after iterating through it and potentially unsetting elements.
    JOB_QUEUE=("${JOB_QUEUE[@]}")

    # Check if all jobs are done to determine if the dispatcher should stop.
    local all_done_check=true
    if [ ${#JOB_QUEUE[@]} -ne 0 ]; then
      all_done_check=false # If the queue is not empty, not all jobs are done.
    else
      # If the queue is empty, check if any jobs are still running or queued (shouldn't be if queue is empty).
      for status in "${JOB_STATUS[@]}"; do
        if [[ "$status" == "QUEUED" || "$status" == "RUNNING" ]]; then
          all_done_check=false
          break
        fi
      done
    fi

    # If all jobs are completed or failed and the queue is empty, stop the dispatcher.
    if [ "$all_done_check" == true ]; then
      echo "[dispatcher] The queue is empty and all jobs have completed or failed. Stopping."
      break
    fi

    # If no jobs were dispatched in this iteration and the queue is not empty,
    # it means all slots are currently occupied or no QUEUED jobs were found.
    if [ "$dispatched_this_loop" -eq 0 ] && [ ${#JOB_QUEUE[@]} -ne 0 ]; then
      sleep 1 # Wait for a second if slots are full but jobs are queued.
    fi

    sleep 0.1 # General polling interval for the dispatcher loop.
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
