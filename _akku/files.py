import sys
import json

target = sys.argv[1]

with open(target, "r") as fp:
  data = json.load(fp)

for file in data["response"]:
  if file["url"].startswith("https://sourceforge.net/projects/waydroid/files/"):
    print(file["url"], file["filename"])

