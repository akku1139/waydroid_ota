sudo mkdir /mnt/work
sudo chown runner:runner -R /mnt/work

targets=($(find system vendor -type f -name "*.json"))

for target in $targets; do
  echo "target" $target
  cmd="python _akku/save.py $target"

  while true; do
    out=($($cmd))
    status=$?

    if [ "$status" -eq 0 ]; then
      wget -O /mnt/work/${out[2]} ${out[1]}

      git add -A
      git commit -m "Update"
      git push

      gh release create dl-${out[0]} "/mnt/work/${out[2]}"
    else
      echo "downloading next file..."
      break
    fi
  done

done
