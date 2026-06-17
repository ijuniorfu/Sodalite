#!/usr/bin/env python3
"""Round-trip-faithful serializer for Xcode's .xcstrings format.

Xcode serializes container-valued keys as `"key" : { ... }` (space before
colon) and scalar-valued keys as `"key": value` (no space before colon),
2-space indent, UTF-8 literal, no trailing newline. This reproduces that
byte-for-byte so we can add entries with a minimal diff.
"""
import json
import sys
from collections import OrderedDict


def dump_value(v, indent):
    pad = "  " * indent
    cpad = "  " * (indent + 1)
    if isinstance(v, dict):
        if not v:
            return "{}"
        lines = ["{"]
        items = list(v.items())
        for i, (k, val) in enumerate(items):
            comma = "," if i < len(items) - 1 else ""
            ks = json.dumps(k, ensure_ascii=False)
            if isinstance(val, (dict, list)):
                lines.append(f"{cpad}{ks} : {dump_value(val, indent + 1)}{comma}")
            else:
                vs = json.dumps(val, ensure_ascii=False)
                lines.append(f"{cpad}{ks}: {vs}{comma}")
        lines.append(f"{pad}}}")
        return "\n".join(lines)
    if isinstance(v, list):
        if not v:
            return "[]"
        lines = ["["]
        for i, val in enumerate(v):
            comma = "," if i < len(v) - 1 else ""
            lines.append(f"{cpad}{dump_value(val, indent + 1)}{comma}")
        lines.append(f"{pad}]")
        return "\n".join(lines)
    return json.dumps(v, ensure_ascii=False)


def dumps(obj):
    return dump_value(obj, 0)


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=OrderedDict)


if __name__ == "__main__":
    # Round-trip self-test: reserialize and compare byte-for-byte.
    path = sys.argv[1]
    with open(path, encoding="utf-8") as f:
        original = f.read()
    obj = json.loads(original, object_pairs_hook=OrderedDict)
    out = dumps(obj)
    if out == original:
        print("ROUND-TRIP OK: byte-identical")
    else:
        # Show first divergence
        for i, (a, b) in enumerate(zip(original, out)):
            if a != b:
                print(f"DIVERGES at char {i}:")
                print("  orig:", repr(original[max(0, i - 40):i + 40]))
                print("  mine:", repr(out[max(0, i - 40):i + 40]))
                break
        else:
            print(f"LENGTH DIFF: orig={len(original)} mine={len(out)}")
