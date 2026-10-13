"""Per-aspect layout. FILM_ASPECT=9x16 (master, default) | 1x1 | 16x9.

The master is designed at 1080x1920. Other aspects keep everything centred horizontally, place
vertical positions by the same fraction of the frame height, and scale type and cards by a factor
chosen so they read at that frame size (not by raw height, which would make captions tiny)."""
import os

ASPECT = os.environ.get('FILM_ASPECT', '9x16')
W, H = {'9x16': (1080, 1920), '1x1': (1080, 1080), '16x9': (1920, 1080)}[ASPECT]
TYPE_S = {'9x16': 1.0, '1x1': 0.80, '16x9': 0.75}[ASPECT]      # type sizes
CARD_S = {'9x16': 1.0, '1x1': 0.62, '16x9': 0.62}[ASPECT]      # hero cards, fly-past faces
SUFFIX = '' if ASPECT == '9x16' else f'_{ASPECT}'


def y(v):
    """A y position designed on the 1920-high master, as the same fraction of this frame."""
    return v * H / 1920.0


def x(v):
    """An x offset from the left edge designed on the 1080-wide master (left-anchored items)."""
    return v * (W / 1080.0 if ASPECT != '16x9' else 1.4)


def px(v):
    return max(8, int(round(v * TYPE_S)))


def cs(v):
    return v * CARD_S
