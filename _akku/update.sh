set -x
set -e

sudo mkdir /mnt/work
sudo chown runner:runner -R /mnt/work

targets=($(find system vendor -type f -name "*.json"))

for target in $targets; do
  echo "target" $target
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
      wget -nv -O /mnt/work/$filename $url
      # aria2c -x10 -s10 --console-log-level=warn -o /mnt/work/$filename $url

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
