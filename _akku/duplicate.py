import sys
import json

target = sys.argv[1]

with open(target, "r") as fp:
  data = json.load(fp)

files = set()

for file in data["response"]:
  l = len(files)
  files.add(file["filename"])
  if l == len(files):
    print(file["filename"], "is duplicated", end=" ")
    if file["url"].startswith("DUPLICATE:"):
      print("(already marked)")
    else:
      file["url"] = "DUPLICATE:" + file["url"]
      print("(fixed)")

with open(target, "w") as fp:
  json.dump(data, fp, indent=4)
