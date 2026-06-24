#!/usr/bin/env python3
# One-shot: replace the four 0.6.0 changelog key blocks in Localizable.xcstrings with full
# 26-locale translated entries, preserving Xcode's exact formatting (surgical block swap).
import json, sys

XCSTRINGS = 'Sodalite/Localizable.xcstrings'
PROOF = sys.argv[1]  # path to the proofread workflow output json

final = json.load(open(PROOF))['result']['final']

KEYMAP = {
    'changelog.0_6_0.engine.title': 'engineTitle',
    'changelog.0_6_0.engine.body': 'engineBody',
    'changelog.0_6_0.playback.title': 'playbackTitle',
    'changelog.0_6_0.playback.body': 'playbackBody',
}

doc = json.load(open(XCSTRINGS))
strings = doc['strings']

# Authoritative en/de come from the file; the other 24 from the proofread output.
def trans_map(key):
    field = KEYMAP[key]
    entry = strings[key]
    assert set(entry.keys()) <= {'extractionState', 'localizations'}, f'unexpected keys in {key}: {entry.keys()}'
    locs = entry['localizations']
    m = {
        'en': locs['en']['stringUnit']['value'],
        'de': locs['de']['stringUnit']['value'],
    }
    for loc, vals in final.items():
        m[loc] = vals[field]
    assert len(m) == 26, f'{key}: expected 26 locales, got {len(m)}'
    return m

def loc_entry(loc, value, last):
    return (
        f'        "{loc}" : {{\n'
        f'          "stringUnit" : {{\n'
        f'            "state": "translated",\n'
        f'            "value": {json.dumps(value, ensure_ascii=False)}\n'
        f'          }}\n'
        f'        }}' + ('' if last else ',') + '\n'
    )

def key_block(key, trailing_comma):
    m = trans_map(key)
    locales = sorted(m.keys())
    es = strings[key].get('extractionState')
    s = f'    "{key}" : {{\n'
    if es is not None:
        s += f'      "extractionState": "{es}",\n'
    s += '      "localizations" : {\n'
    for i, loc in enumerate(locales):
        s += loc_entry(loc, m[loc], i == len(locales) - 1)
    s += '      }\n'
    s += '    }' + (',' if trailing_comma else '') + '\n'
    return s

lines = open(XCSTRINGS).readlines()
out = []
i = 0
replaced = []
while i < len(lines):
    stripped = lines[i].strip()
    matched = next((k for k in KEYMAP if stripped == f'"{k}" : {{'), None)
    if matched:
        j = i + 1
        while not (len(lines[j]) - len(lines[j].lstrip(' ')) == 4 and lines[j].lstrip().startswith('}')):
            j += 1
        trailing = lines[j].strip() == '},'
        out.append(key_block(matched, trailing))
        replaced.append(matched)
        i = j + 1
    else:
        out.append(lines[i])
        i += 1

assert sorted(replaced) == sorted(KEYMAP.keys()), f'replaced {replaced}, expected all 4'

text = ''.join(out)
# Validate it still parses and every target key has 26 translated locales.
check = json.loads(text)
for k in KEYMAP:
    locs = check['strings'][k]['localizations']
    assert len(locs) == 26, f'{k}: {len(locs)} locales after write'
    bad = [l for l, v in locs.items() if v['stringUnit']['state'] != 'translated']
    assert not bad, f'{k}: not translated: {bad}'

open(XCSTRINGS, 'w').write(text)
print(f'OK: replaced {len(replaced)} key blocks, each now 26 locales / all translated.')
