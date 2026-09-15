"""Locate the Scroll Anytime icon on a Springboard screenshot so the demo can TAP it.

The video has to begin the way Apple asked, at the Home Screen with a real tap on the icon, and a
freshly installed app lands wherever there is a free slot — which on a clean Simulator is not even
the first page. So this is called once per page while the driver swipes through them.

Two things the first attempt got wrong, both of which ended with the walk recorded inside Apple's
Wallet app: the threshold was low enough that any icon-shaped thing matched, and the template was
the full-bleed 1024 artwork, whose corners Springboard masks away. Now the template is the icon
iOS itself rasterised into the installed bundle, both sides are centre-cropped past the corner
radius, and the bar to declare a match is high.

Prints "x y" in POINTS on success; exits 3 when this page does not hold the icon.
"""
import sys
import cv2

shot_path, icon_path, scale = sys.argv[1], sys.argv[2], float(sys.argv[3])
FLOOR = float(sys.argv[4]) if len(sys.argv) > 4 else 0.62

shot = cv2.imread(shot_path, cv2.IMREAD_COLOR)
icon = cv2.imread(icon_path, cv2.IMREAD_COLOR)
if shot is None or icon is None:
    print('ERR unreadable image', file=sys.stderr)
    sys.exit(2)

# Springboard masks the icon into a squircle, so the corners of the source artwork are never on
# screen. Compare only the middle, where the two are actually the same pixels.
def core(img):
    h, w = img.shape[:2]
    m = int(min(h, w) * 0.18)
    return img[m:h - m, m:w - m]

icon = core(icon)

best_pt, best_score, best_side = None, -1.0, 0
for side in range(90, 240, 6):
    t = cv2.resize(icon, (side, side), interpolation=cv2.INTER_AREA)
    if t.shape[0] >= shot.shape[0] or t.shape[1] >= shot.shape[1]:
        continue
    _, mx, _, loc = cv2.minMaxLoc(cv2.matchTemplate(shot, t, cv2.TM_CCOEFF_NORMED))
    if mx > best_score:
        best_pt, best_score, best_side = (loc[0] + side / 2, loc[1] + side / 2), mx, side

print(f'best {best_score:.3f} at {best_pt} side {best_side}', file=sys.stderr)
if best_score < FLOOR:
    sys.exit(3)
print(f'{int(best_pt[0] / scale)} {int(best_pt[1] / scale)}')
