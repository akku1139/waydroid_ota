targets=$(find system vendor -type f -name "*.json")

for target in $targets; do
  echo "target" $target

  python _akku/duplicate.py "$target"
done
