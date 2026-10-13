"""Contact sheet: sheet.py out.jpg img1 img2 ... [--h 900] [--labels a,b,c] [--corners json1,json2]"""
import sys, json
from PIL import Image, ImageDraw, ImageFont
args = sys.argv[1:]
out = args.pop(0)
H = 900; labels = None; corners = None
if '--h' in args: i = args.index('--h'); H = int(args[i+1]); del args[i:i+2]
if '--labels' in args: i = args.index('--labels'); labels = args[i+1].split(','); del args[i:i+2]
if '--corners' in args: i = args.index('--corners'); corners = args[i+1].split(','); del args[i:i+2]
ims = []
for k, f in enumerate(args):
    im = Image.open(f).convert('RGB')
    s = H / im.height
    im2 = im.resize((round(im.width * s), H), Image.LANCZOS)
    d = ImageDraw.Draw(im2)
    if corners and corners[k] != '-':
        c = json.load(open(corners[k]))['frames'][0]['corners']
        if c:
            pts = [(x * s, y * s) for x, y in c]
            d.line(pts + [pts[0]], fill=(255, 0, 255), width=2)
    if labels:
        f = ImageFont.truetype('assets/fonts/Inter-600.ttf', 22)
        d.rectangle((0, 0, im2.width, 34), fill=(0, 0, 0))
        d.text((8, 5), labels[k], font=f, fill=(255, 220, 120))
    ims.append(im2)
W = sum(i.width for i in ims) + 6 * (len(ims) - 1)
c = Image.new('RGB', (W, H), (40, 40, 40))
x = 0
for i in ims: c.paste(i, (x, 0)); x += i.width + 6
c.save(out, quality=88)
print(out, c.size)
