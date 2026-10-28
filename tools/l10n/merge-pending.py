"""Merges tools/l10n/pending-*.json ({"English key": {"de": "...", ...}}) into keys.json and <lang>.json,
then removes the pending files. Run build-catalog.py afterwards."""
import glob, json, os
here = os.path.dirname(os.path.abspath(__file__))
LANGS = ["de", "fr", "it", "es", "pt-BR", "nl", "tr", "pl", "ja", "ko", "zh-Hans", "zh-Hant", "hi", "ar", "id"]
keys = json.load(open(os.path.join(here, "keys.json")))
tables = {l: json.load(open(os.path.join(here, f"{l}.json"))) for l in LANGS}
for path in sorted(glob.glob(os.path.join(here, "pending-*.json"))):
    pending = json.load(open(path))
    for k, tr in pending.items():
        if k not in keys: keys.append(k)
        for l in LANGS:
            if tr.get(l): tables[l][k] = tr[l]
    print(f"{os.path.basename(path)}: {len(pending)} strings")
    os.remove(path)
json.dump(sorted(set(keys)), open(os.path.join(here, "keys.json"), "w"), indent=1, ensure_ascii=False)
for l, t in tables.items():
    json.dump(dict(sorted(t.items())), open(os.path.join(here, f"{l}.json"), "w"), indent=1, ensure_ascii=False)
