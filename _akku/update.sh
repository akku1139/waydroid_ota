set -x
set -e

sudo mkdir /mnt/work
sudo chown runner:runner -R /mnt/work


# Job manager (by Gemini 2.5 Flash)

# Max concurrent downloads
MAX_DOWNLOADS=10

# Associative array to manage active download jobs
# Key: PID, Value: "URL:FILENAME"
declare -A ACTIVE_DOWNLOADS

# Associative array for quick lookup: URL to PID
# Key: URL, Value: PID
declare -A URL_TO_PID

# Associative array for quick lookup: PID to URL
# Key: PID, Value: URL
declare -A PID_TO_URL

# Associative array to store all URL to filename mappings from the list file
# Key: URL, Value: FILENAME
declare -A URL_TO_FILENAME

# Function to check for finished jobs and update ACTIVE_DOWNLOADS
check_finished_jobs() {
  for PID in "${!ACTIVE_DOWNLOADS[@]}"; do
    # Check if the process exists (i.e., if it has finished)
    if ! kill -0 "$PID" 2>/dev/null; then
      # Get job info from the finished process
      JOB_INFO="${ACTIVE_DOWNLOADS[$PID]}"
      URL=$(echo "${JOB_INFO}" | cut -d':' -f1)
      FILENAME=$(echo "${JOB_INFO}" | cut -d':' -f2)

      echo "Download finished detected: ${FILENAME} (PID: ${PID})"
      unset ACTIVE_DOWNLOADS["$PID"] # Remove from active downloads
      unset URL_TO_PID["${URL}"]     # Remove from URL_TO_PID mapping
      unset PID_TO_URL["${PID}"]     # Remove from PID_TO_URL mapping
    fi
  done
}

# Function to add a download job to the queue
add_download_job() {
  URL=$1
  FILENAME=$2

  # If the job is already added (or still active), do nothing
  if [[ -n "${URL_TO_PID[${URL}]}" ]]; then
    echo "Job ${FILENAME} is already in the queue or active."
    return 0
  fi

  # Wait if the number of concurrent downloads exceeds MAX_DOWNLOADS
  while (( ${#ACTIVE_DOWNLOADS[@]} >= MAX_DOWNLOADS )); do
    echo "Waiting... (Current downloads: ${#ACTIVE_DOWNLOADS[@]}/${MAX_DOWNLOADS})"
    check_finished_jobs # Check for finished jobs before waiting
    # Wait for any background job to complete (Bash 4.3+ required for wait -n)
    wait -n || {
      # If wait -n fails (e.g., no more child processes), break if no active jobs
      if (( ${#ACTIVE_DOWNLOADS[@]} == 0 )); then
        break
      fi
    }
    check_finished_jobs # Check again after waiting
  done

  # Execute wget command in the background
  echo "Starting download: ${URL}"
  wget -nv -O /mnt/work/$FILENAME $URL &
  PID=$! # Get the PID of the background process

  # Store job information
  ACTIVE_DOWNLOADS["$PID"]="${URL}:${FILENAME}"
  URL_TO_PID["${URL}"]="$PID"
  PID_TO_URL["$PID"]="${URL}"

  echo "Job ${FILENAME} (PID: ${PID}) added."
}

# Function to wait for a specific URL's download to complete
# If the job is not running, it will be started.
wait_for_download() {
  TARGET_URL=$1

  # Verify if the target URL is in our predefined list
  if [[ -z "${URL_TO_FILENAME[${TARGET_URL}]}" ]]; then
    echo "Error: ${TARGET_URL} was not found in the download list."
    return 1
  fi

  TARGET_FILENAME="${URL_TO_FILENAME[${TARGET_URL}]}"

  # Check if the job is currently running
  if [[ -z "${URL_TO_PID[${TARGET_URL}]}" ]]; then
    echo "Download for ${TARGET_FILENAME} has not started yet. Starting it now."
    add_download_job "${TARGET_URL}" "${TARGET_FILENAME}"
    # After calling add_download_job, the PID should be available in URL_TO_PID.
    # Re-fetch PID as add_download_job might have waited due to concurrency limits.
    TARGET_PID="${URL_TO_PID[${TARGET_URL}]}"
  else
    # If already running, get its PID
    TARGET_PID="${URL_TO_PID[${TARGET_URL}]}"
    echo "Download for ${TARGET_FILENAME} is already running. Waiting for completion."
  fi

  # Wait until the target PID is removed from ACTIVE_DOWNLOADS (i.e., job completes)
  while [[ -n "${ACTIVE_DOWNLOADS[${TARGET_PID}]}" ]]; do
    check_finished_jobs # Check for finished jobs
    sleep 1 # Wait for 1 second before re-checking
  done

  echo "Download completed for: ${TARGET_FILENAME} (PID: ${TARGET_PID})"
}

echo "Starting download job queue. Max concurrent downloads: ${MAX_DOWNLOADS}"

# Done


targets=$(find system vendor -type f -name "*.json")

for target in $targets; do
  echo "target" $target
  cmd="python _akku/save.py $target"


  # by Gemini

  # Read the URL list file and pre-load all URL to filename mappings
  while read -r url filename || [ -n "$url" ]; do
    if [[ -n "$url" && -n "$filename" ]]; then
      URL_TO_FILENAME["${url}"]="${filename}"
    fi
  done < <(python _akku/files.py $target)

  # Add all download jobs to the queue (asynchronously)
  # The actual parallel execution is limited by MAX_DOWNLOADS in add_download_job
  for url in "${!URL_TO_FILENAME[@]}"; do
    add_download_job "${url}" "${URL_TO_FILENAME[${url}]}"
  done

  ###


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
      wait_for_download $url

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
