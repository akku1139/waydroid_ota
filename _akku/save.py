import sys
import json

target = sys.argv[1]

with open(target, "r") as fp:
  data = json.load(fp)

for file in data["response"]:
  if file["url"].startswith("https://sourceforge.net/projects/waydroid/files/"):
    print(file["id"])
    print(file["url"])
    print(file["filename"])
    file["url"] = f'https://github.com/akku1139/waydroid_ota/releases/download/dl-{file["id"]}/{file["filename"]}'

    with open(target, "w") as fp:
      json.dump(data, fp, indent=4)

    sys.exit(0)

sys.exit(1)
