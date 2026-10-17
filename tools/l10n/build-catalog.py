"""Builds Resources/Localizable.xcstrings from keys.json (English) and <lang>.json translations.
Fails if a language misses a key or changes format specifiers, so no string ships untranslated."""
import json, os, re, sys
here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(os.path.dirname(here))
LANGS = ["de", "fr", "it", "es", "pt-BR", "nl", "tr", "pl", "ja", "ko", "zh-Hans", "zh-Hant", "hi", "ar", "id"]
keys = [k for k in json.load(open(os.path.join(here, "keys.json"))) if k.strip()]
spec = re.compile(r"%(?:\d+\$)?(@|lld)")
def tokens(s): return sorted(spec.findall(s))
errors = []
strings = {}
tables = {}
for lang in LANGS:
    path = os.path.join(here, f"{lang}.json")
    if not os.path.exists(path):
        errors.append(f"{lang}: missing file"); continue
    tables[lang] = json.load(open(path))
for k in keys:
    loc = {}
    for lang, t in tables.items():
        v = t.get(k)
        if not v:
            errors.append(f"{lang}: missing '{k}'"); continue
        if tokens(v) != tokens(k):
            errors.append(f"{lang}: specifiers differ in '{k}' → '{v}'"); continue
        loc[lang] = {"stringUnit": {"state": "translated", "value": v}}
    strings[k] = {"localizations": loc} if loc else {}
catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
out = os.path.join(root, "Resources", "Localizable.xcstrings")
json.dump(catalog, open(out, "w"), indent=2, ensure_ascii=False, sort_keys=True)
print(f"{len(keys)} strings × {len(tables)} languages → {out}")
if errors:
    print("\n".join(errors[:50])); print(f"{len(errors)} problems"); sys.exit(1)
