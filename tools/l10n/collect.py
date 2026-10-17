"""Collects every localizable string the Swift compiler found (.stringsdata) into keys.json."""
import glob, json, os, sys
dd = os.path.expanduser(sys.argv[1])
out = sys.argv[2]
keys = {}
for f in glob.glob(os.path.join(dd, "Build/Intermediates.noindex/Formwerk.build/Debug/Formwerk.build/**/*.stringsdata"), recursive=True):
    data = json.load(open(f))
    for table in data.get("tables", {}).values():
        for e in table:
            keys[e["key"]] = e.get("comment", "")
json.dump(sorted(keys), open(out, "w"), indent=1, ensure_ascii=False)
print(len(keys), "strings")
