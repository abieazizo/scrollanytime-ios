"""Find an app icon on the Home Screen BY NAME, from idb's accessibility dump on stdin.

Template matching was the wrong tool for this. Twice it scored Apple's Wallet icon above the bar
and the driver walked into the wrong app, because "colourful rounded square roughly this size" is
most of a Home Screen. Springboard publishes every icon's label and frame through accessibility,
so ask for the one called Scroll Anytime and take the frame it hands back.

Reads idb's JSON (an array, or one object per line) and prints "x y" in POINTS, or exits 3.
"""
import json
import sys

WANT = (sys.argv[1] if len(sys.argv) > 1 else 'Scroll Anytime').strip().lower()

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

def label(e):
    for k in ('AXLabel', 'AXUniqueId', 'title', 'name', 'label'):
        v = e.get(k)
        if isinstance(v, str) and v.strip():
            return v.strip()
    return ''

hits = [e for e in elements if label(e).lower() == WANT]
if not hits:                                   # icon labels sometimes carry a badge suffix
    hits = [e for e in elements if label(e).lower().startswith(WANT)]
print(f'{len(elements)} elements, {len(hits)} named {WANT!r}', file=sys.stderr)
if not hits:
    sys.exit(3)

f = hits[0].get('frame') or {}
try:
    x = float(f['x']) + float(f['width']) / 2
    y = float(f['y']) + float(f['height']) / 2
except (KeyError, TypeError, ValueError):
    print(f'no usable frame on {hits[0]!r}', file=sys.stderr)
    sys.exit(4)
print(f'{int(x)} {int(y)}')
