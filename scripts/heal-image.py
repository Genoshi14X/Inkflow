"""Restore brush strokes using nearby texture patches or smooth inpainting."""
import json
import math
import sys
from pathlib import Path


def restore_texture(image, mask, donor_exclusion=None):
    """Fill from fully unmasked donor patches; never average away the source grain."""
    import cv2
    import numpy as np

    unknown = mask > 0
    original_known = (~unknown).astype(np.uint8)
    if donor_exclusion is not None:
        original_known[donor_exclusion > 0] = 0
    # Use the largest patch with enough unmasked source material for this crop.
    half = min(7, (min(mask.shape) - 1) // 2)
    while half >= 1:
        patch = 2 * half + 1
        donors = cv2.erode(original_known, np.ones((patch, patch), np.uint8),
                           borderType=cv2.BORDER_CONSTANT, borderValue=0) > 0
        if np.any(donors):
            break
        half -= 1
    if half < 1:
        raise ValueError('Недостаточно фона рядом с мазком. Уменьшите размер кисти.')
    output = image.copy()
    source = image.astype(np.float32)
    kernel = np.ones((patch, patch), np.uint8)
    small = np.ones((3, 3), np.uint8)
    height, width = mask.shape
    while np.any(unknown):
        known = (~unknown).astype(np.uint8)
        boundary = unknown & (cv2.dilate(known, small) > 0)
        confidence = cv2.boxFilter(known.astype(np.float32), -1, (patch, patch), normalize=True,
                                  borderType=cv2.BORDER_CONSTANT)
        # Continue strong edges from the unmasked context before filling flat interiors.
        gray = cv2.GaussianBlur(cv2.cvtColor(output, cv2.COLOR_RGB2GRAY).astype(np.float32), (0, 0), 1.5)
        gx = cv2.Sobel(gray, -1, 1, 0)
        gy = cv2.Sobel(gray, -1, 0, 1)
        safe = cv2.erode(known, np.ones((7, 7), np.uint8), borderType=cv2.BORDER_CONSTANT, borderValue=0)
        edge = cv2.dilate(np.minimum(np.hypot(gx, gy), 128) * safe, kernel) / 128
        priority = np.where(boundary, confidence * (0.02 + edge), -1)
        y, x = np.unravel_index(np.argmax(priority), priority.shape)
        y = int(np.clip(y, half, height - half - 1))
        x = int(np.clip(x, half, width - half - 1))
        ty, tx = y - half, x - half
        target = output[ty:ty+patch, tx:tx+patch].astype(np.float32)
        match_mask = np.repeat(known[ty:ty+patch, tx:tx+patch, None], 3, axis=2)
        # Search locally first to keep both the background and processing time local.
        sy, sx = max(0, y-128), max(0, x-128)
        ey, ex = min(height, y+129), min(width, x+129)
        valid = donors[sy+half:ey-half, sx+half:ex-half]
        if not np.any(valid):
            sy, sx, ey, ex = 0, 0, height, width
            valid = donors[half:height-half, half:width-half]
        scores = cv2.matchTemplate(source[sy:ey, sx:ex], target, cv2.TM_SQDIFF, mask=match_mask)
        scores = np.maximum(scores, 0) / max(1, int(np.count_nonzero(match_mask)))
        yy, xx = np.indices(scores.shape)
        scores += ((yy+sy-ty)**2 + (xx+sx-tx)**2) * 0.0001
        scores[~valid] = np.inf
        dy, dx = np.unravel_index(np.argmin(scores), scores.shape)
        donor = image[sy+dy:sy+dy+patch, sx+dx:sx+dx+patch]
        fill = unknown[ty:ty+patch, tx:tx+patch]
        output[ty:ty+patch, tx:tx+patch][fill] = donor[fill]
        unknown[ty:ty+patch, tx:tx+patch] = False
    return output


def heal(source, destination, stroke):
    import cv2
    import numpy as np
    from PIL import Image

    diameter = float(stroke['diameter'])
    points = stroke['points']
    if not math.isfinite(diameter) or not 2 <= diameter <= 400 or not 1 <= len(points) <= 50000:
        raise ValueError('Invalid brush stroke')
    if any(not math.isfinite(p[k]) or not 0 <= p[k] <= 1 for p in points for k in ('x', 'y')):
        raise ValueError('Invalid brush coordinates')
    with Image.open(source) as original:
        if original.mode.startswith('I') or original.mode == 'F':
            raise ValueError('Для кисти требуется 8-битное изображение. Сохраните его в обычный PNG.')
        info = original.info.copy()
        rgba = np.array(original.convert('RGBA'))
    height, width = rgba.shape[:2]
    coordinates = [(round(p['x'] * (width - 1)), round(p['y'] * (height - 1))) for p in points]
    radius = math.ceil(diameter / 2)
    method = stroke.get('method', 'texture')
    if method not in ('texture', 'smooth'):
        raise ValueError('Invalid restoration method')
    margin = radius + (80 if method == 'texture' else 16)
    left = max(0, min(p[0] for p in coordinates) - margin)
    top = max(0, min(p[1] for p in coordinates) - margin)
    right = min(width, max(p[0] for p in coordinates) + margin + 1)
    bottom = min(height, max(p[1] for p in coordinates) + margin + 1)
    mask = np.zeros((bottom - top, right - left), dtype=np.uint8)
    local = [(x - left, y - top) for x, y in coordinates]
    for point in local:
        cv2.circle(mask, point, radius, 255, -1)
    for start, end in zip(local, local[1:]):
        cv2.line(mask, start, end, 255, radius * 2 + 1)
    if np.all(mask):
        raise ValueError('Оставьте вокруг мазка участок фона для восстановления.')
    region = rgba[top:bottom, left:right]
    rgb = np.ascontiguousarray(region[:, :, :3])
    repaired = restore_texture(rgb, mask) if method == 'texture' else cv2.inpaint(rgb, mask, 3, cv2.INPAINT_TELEA)
    region[mask > 0, :3] = repaired[mask > 0]
    options = {key: info[key] for key in ('icc_profile', 'dpi') if key in info}
    # Alpha and all pixels outside the stroke are copied without modification.
    Image.fromarray(rgba).save(destination, format='PNG', **options)


if __name__ == '__main__':
    try:
        heal(sys.argv[1], sys.argv[2], json.loads(Path(sys.argv[3]).read_text()))
    except ImportError:
        sys.exit('Не найден OpenCV. Установите opencv-python-headless в Python, выбранный для nunif.')
    except Exception as error:
        sys.exit(str(error))
