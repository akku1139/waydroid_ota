# set -x
set -e

sudo mkdir /mnt/work
sudo chown runner:runner -R /mnt/work

targets=$(find system vendor -type f -name "*.json")


## Download manager

# key: filename, value: url
declare -A FILENAME_URL

wait_for_file_foreground() {
  filename=$1
  url=${FILENAME_URL[$filename]}
  wget -nv -O /mnt/work/$filename $url
}

## End


for target in $targets; do
  echo "target" $target

  while read -r url filename; do
    [[ "$url" =~ ^#.* ]] && continue
    [ -z "$url" ] && continue

    FILENAME_URL[$filename]=$url
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
