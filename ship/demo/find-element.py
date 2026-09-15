"""Find an on-screen control BY NAME in idb's accessibility dump, and print its centre in POINTS.

Generalised from the Home Screen icon finder, for the same reason: every coordinate in this driver
that was measured off a screenshot eventually landed on the wrong thing, on a different device or
one second too early. Names do not move.

  idb ui describe-all | python3 find-element.py "Continue without an account" [--contains]

Exit 3 means the label is not on screen, which is a legitimate answer the caller can retry on.
"""
import json
import sys

args = [a for a in sys.argv[1:] if not a.startswith('--')]
CONTAINS = '--contains' in sys.argv
WANT = (args[0] if args else '').strip().lower()

raw = sys.stdin.read().strip()
elements = []
try:
    parsed = json.loads(raw)
    elements = parsed if isinstance(parsed, list) else [parsed]
except json.JSONDecodeError:
    for line in raw.splitlines():
        line = line.strip().rstrip(',')
        if not line or line in '[]':
            continue
        try:
            elements.append(json.loads(line))
        except json.JSONDecodeError:
            pass

def labels(e):
    out = []
    for k in ('AXLabel', 'AXValue', 'title', 'name', 'label', 'AXUniqueId'):
        v = e.get(k)
        if isinstance(v, str) and v.strip():
            out.append(v.strip().lower())
    return out

def hit(e):
    ls = labels(e)
    if CONTAINS:
        return any(WANT in l for l in ls)
    return any(l == WANT for l in ls)

hits = [e for e in elements if hit(e)]
print(f'{len(elements)} elements, {len(hits)} matching {WANT!r} (contains={CONTAINS})', file=sys.stderr)
if not hits:
    sys.exit(3)

# Smallest match: labels nest, and the innermost element is the one that takes the tap.
def area(e):
    f = e.get('frame') or {}
    try:
        return float(f['width']) * float(f['height'])
    except (KeyError, TypeError, ValueError):
        return float('inf')

best = min(hits, key=area)
f = best.get('frame') or {}
try:
    print(f"{int(float(f['x']) + float(f['width']) / 2)} {int(float(f['y']) + float(f['height']) / 2)}")
except (KeyError, TypeError, ValueError):
    print(f'no usable frame on {best!r}', file=sys.stderr)
    sys.exit(4)
