"""Conservative, OCR-guided text removal. No pixels outside detected glyph masks change."""
import importlib.util
import json
import math
import sys
from pathlib import Path


def bounds(box, width, height, padding=0):
    values = [float(box[k]) for k in ('x', 'y', 'width', 'height')]
    if not all(math.isfinite(v) for v in values) or min(values) < 0 or min(values[2:]) <= 0:
        raise ValueError('Некорректная область OCR.')
    x, y, w, h = values
    if x+w > 1.000001 or y+h > 1.000001:
        raise ValueError('Область OCR выходит за границы страницы.')
    return (max(0, math.floor(x*width)-padding), max(0, math.floor(y*height)-padding),
            min(width, math.ceil((x+w)*width)+padding), min(height, math.ceil((y+h)*height)+padding))


def glyph_mask(rgb, region):
    import cv2
    import numpy as np

    height, width = rgb.shape[:2]
    x, y, right, bottom = bounds(region['box'], width, height)
    lines = region.get('lines') or []
    line_count = max(1, int(region.get('lineCount', 1)))
    letter_height = float(np.median([b['height']*height for b in lines])) if lines else (bottom-y)/line_count
    letter_height = max(4, letter_height)
    padding = max(1, min(6, round(letter_height*0.05)))
    margin = max(16, min(160, round(letter_height*1.5)))
    left, top = max(0, x-margin), max(0, y-margin)
    end_x, end_y = min(width, right+margin), min(height, bottom+margin)
    crop = rgb[top:end_y, left:end_x]
    gray = cv2.cvtColor(crop, cv2.COLOR_RGB2GRAY)
    allowed = np.zeros(gray.shape, np.uint8)
    for box in lines or [region['box']]:
        bx, by, br, bb = bounds(box, width, height, padding)
        allowed[max(0, by-top):min(end_y, bb)-top, max(0, bx-left):min(end_x, br)-left] = 255
    # Never turn transparent lettering/empty regions into opaque paint.
    context = allowed == 0
    sample = gray[context]
    if sample.size < 16:
        return (left, top, end_x, end_y), allowed*0, 'skipped'
    low, high = np.percentile(sample, [10, 90])
    smooth = high-low < 16
    if smooth:
        background = float(np.median(sample))
        dark = np.maximum(background-gray.astype(np.float32), 0)
        light = np.maximum(gray.astype(np.float32)-background, 0)
        threshold = max(18, float(high-low)*1.5)
    else:
        kernel_size = max(5, min(81, int(letter_height*0.65) | 1))
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (kernel_size, kernel_size))
        dark = cv2.morphologyEx(gray, cv2.MORPH_BLACKHAT, kernel)
        light = cv2.morphologyEx(gray, cv2.MORPH_TOPHAT, kernel)
        # Screentone dots are part of the background, not letters. Require contrast
        # stronger than the surrounding pattern, and abstain if it is ambiguous.
        threshold = max(22, min(float(np.percentile(dark[context], 97))*1.15+5, float(dark.max())*0.65))
    def candidates(response, cutoff, polarity):
        seed = (response > cutoff).astype(np.uint8)
        count, labels, stats, _ = cv2.connectedComponentsWithStats(seed, connectivity=8)
        keep = np.zeros(count, np.uint8)
        punctuation = []
        for i in range(1, count):
            bx, by, bw, bh, area = stats[i]
            if area < max(2, letter_height*0.025) or bh > letter_height*1.65:
                continue
            # Exclude balloon contours, panel borders, and long drawing strokes.
            if bw > max(letter_height*3, (right-x)*0.9) or (bw > bh*12 and bh < letter_height*0.18):
                continue
            component = labels[by:by+bh, bx:bx+bw] == i
            if not smooth:
                intensity = float(np.median(gray[by:by+bh, bx:bx+bw][component]))
                contrast = (float(np.median(sample))-intensity)*polarity
                if contrast < max(12, (high-low)*0.25):
                    continue
            overlap = np.count_nonzero(component & (allowed[by:by+bh, bx:bx+bw] > 0))
            if overlap < area*0.94 or area > np.count_nonzero(allowed)*0.55:
                continue
            if not smooth and bh < letter_height*0.18:
                punctuation.append(i)
            else:
                keep[i] = 255
        if punctuation and np.any(keep):
            radius = max(1, round(letter_height*0.3))
            nearby = cv2.dilate(keep[labels], np.ones((radius*2+1, radius*2+1), np.uint8))
            for i in punctuation:
                if np.any(nearby[labels == i]):
                    keep[i] = 255
        return keep[labels]
    dark_mask = candidates(dark, threshold, 1)
    light_threshold = threshold if smooth else max(22, min(float(np.percentile(light[context], 97))*1.15+5, float(light.max())*0.65))
    light_mask = candidates(light, light_threshold, -1)
    dark_count, light_count = np.count_nonzero(dark_mask), np.count_nonzero(light_mask)
    if max(dark_count, light_count) < 2 or (not smooth and min(dark_count, light_count) > max(dark_count, light_count)*0.7):
        return (left, top, end_x, end_y), allowed*0, 'skipped'
    mask = dark_mask if dark_count >= light_count else light_mask
    # Cover antialiasing and the edge of each glyph, not its rectangular OCR box.
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (padding*2+1, padding*2+1))
    mask = cv2.dilate(mask, kernel)
    mask[allowed == 0] = 0
    if np.count_nonzero(mask) > np.count_nonzero(allowed)*(0.7 if smooth else 0.88):
        return (left, top, end_x, end_y), allowed*0, 'skipped'
    return (left, top, end_x, end_y), mask, 'smooth' if smooth else 'texture'


def clean(source, destination, configuration):
    import cv2
    import numpy as np
    from PIL import Image

    regions = configuration['regions']
    if not isinstance(regions, list) or not 1 <= len(regions) <= 5000:
        raise ValueError('Нет подходящих областей OCR для очистки.')
    with Image.open(source) as original:
        if original.mode.startswith('I') or original.mode == 'F':
            raise ValueError('Для очистки требуется 8-битное изображение. Сохраните страницу в обычный PNG.')
        info = original.info.copy()
        rgba = np.array(original.convert('RGBA'))
    rgb = np.ascontiguousarray(rgba[:, :, :3])
    height, width = rgb.shape[:2]
    original = rgb.copy()
    masks = []
    all_masks = np.zeros((height, width), np.uint8)
    donor_exclusion = np.zeros((height, width), np.uint8)
    for region in regions:
        x, y, r, b = bounds(region['box'], width, height, 4)
        donor_exclusion[y:b, x:r] = 255
        rect, mask, method = glyph_mask(original, region)
        l, t, r, b = rect
        mask[rgba[t:b, l:r, 3] == 0] = 0
        all_masks[t:b, l:r] |= mask
        masks.append((rect, mask, method))
    module = importlib.util.spec_from_file_location('inkflow_healing', Path(__file__).with_name('heal-image.py'))
    healing = importlib.util.module_from_spec(module)
    module.loader.exec_module(healing)
    report = {'smooth': 0, 'texture': 0, 'skipped': 0, 'changedPixels': 0}
    for (l, t, r, b), mask, method in masks:
        if not np.any(mask):
            report['skipped'] += 1
            continue
        crop = np.ascontiguousarray(original[t:b, l:r])
        # All neighbouring text is excluded as a texture donor, even when it is
        # going to be removed later. This prevents copying letters into the fill.
        if method == 'texture':
            try:
                repaired = healing.restore_texture(crop, all_masks[t:b, l:r], donor_exclusion[t:b, l:r])
            except ValueError:
                report['skipped'] += 1
                continue
        else:
            repaired = cv2.inpaint(crop, all_masks[t:b, l:r], 3, cv2.INPAINT_TELEA)
        target = rgb[t:b, l:r]
        target[mask > 0] = repaired[mask > 0]
        report[method] += 1
    changed = np.any(rgb != original, axis=2)
    report['changedPixels'] = int(np.count_nonzero(changed))
    rgba[:, :, :3] = rgb
    options = {key: info[key] for key in ('icc_profile', 'dpi') if key in info}
    Image.fromarray(rgba).save(destination, format='PNG', **options)
    Path(str(destination)+'.json').write_text(json.dumps(report), encoding='utf-8')
    return report


if __name__ == '__main__':
    try:
        clean(sys.argv[1], sys.argv[2], json.loads(Path(sys.argv[3]).read_text(encoding='utf-8')))
    except ImportError:
        sys.exit('Не найден OpenCV или Pillow. Установите opencv-python-headless и Pillow в Python, выбранный для nunif.')
    except Exception as error:
        sys.exit(str(error))
