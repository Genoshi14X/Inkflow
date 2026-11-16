import importlib.util
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('cleaning', ROOT/'scripts/clean-text.py')
cleaning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cleaning)


class CleaningTests(unittest.TestCase):
    def fixture(self, background, text='HELLO!', fill=0):
        image = Image.fromarray(background.copy())
        draw = ImageDraw.Draw(image)
        font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 32)
        box = draw.textbbox((120, 90), text, font=font, stroke_width=0)
        draw.text((120, 90), text, font=font, fill=(fill,)*3)
        x, y, r, b = box
        normalized = {'x': x/image.width, 'y': y/image.height,
                      'width': (r-x)/image.width, 'height': (b-y)/image.height}
        return np.array(image), {'box': normalized, 'lines': [normalized], 'lineCount': 1}

    def run_clean(self, pixels, region):
        with tempfile.TemporaryDirectory() as folder:
            source, output = Path(folder)/'in.png', Path(folder)/'out.png'
            Image.fromarray(pixels).save(source)
            report = cleaning.clean(source, output, {'regions': [region]})
            result = np.array(Image.open(output))
            if pixels.shape[2] == 3: result = result[:, :, :3]
            return result, report

    def test_flat_bubble_and_black_background(self):
        for value, fill in [(255, 0), (160, 0), (0, 255)]:
            reference = np.full((240, 420, 3), value, np.uint8)
            # A drawing outside the OCR area must survive byte-for-byte.
            reference[30:180, 40:43] = 255-value
            damaged, region = self.fixture(reference, fill=fill)
            result, report = self.run_clean(damaged, region)
            self.assertEqual(report['smooth'], 1)
            self.assertEqual(report['texture'], 0)
            mask = np.any(damaged != reference, axis=2)
            self.assertLess(np.abs(result[mask].astype(float)-reference[mask]).mean(), 3)
            x, y, r, b = cleaning.bounds(region['box'], 420, 240, 3)
            outside = np.ones((240, 420), bool); outside[y:b, x:r] = False
            np.testing.assert_array_equal(result[outside], damaged[outside])

    def test_screentone_does_not_become_blurred(self):
        y, x = np.indices((240, 420))
        tone = np.where((x % 6-2)**2+(y % 6-2)**2 < 3, 140, 210).astype(np.uint8)
        reference = np.repeat(tone[:, :, None], 3, axis=2)
        damaged, region = self.fixture(reference)
        result, report = self.run_clean(damaged, region)
        self.assertEqual(report['texture'], 1)
        ink = np.all(damaged == 0, axis=2)
        self.assertGreater(np.count_nonzero(ink), 300)
        self.assertGreater(result[ink].std(), 15)
        self.assertGreaterEqual(int(result[ink].min()), 140)
        self.assertLess(np.abs(result[ink].astype(float)-reference[ink]).mean(), 15)
        # Most background pixels inside the box also remain unchanged.
        mask_rect, mask, _ = cleaning.glyph_mask(damaged, region)
        l, t, r, b = mask_rect
        unchanged = np.ones(ink.shape, bool); unchanged[t:b, l:r] = mask == 0
        np.testing.assert_array_equal(result[unchanged], damaged[unchanged])

    def test_high_contrast_screentone_and_empty_pattern(self):
        y, x = np.indices((240, 420))
        for dark in (0, 70):
            tone = np.where((x % 6-2)**2+(y % 6-2)**2 < 3, dark, 210).astype(np.uint8)
            reference = np.repeat(tone[:, :, None], 3, axis=2)
            damaged, region = self.fixture(reference)
            result, report = self.run_clean(damaged, region)
            self.assertEqual(report['texture'], 1)
            ink = np.any(damaged != reference, axis=2)
            self.assertLess(np.abs(result[ink].astype(float)-reference[ink]).mean(), 15)
            untouched, blank_report = self.run_clean(reference, region)
            self.assertEqual(blank_report['changedPixels'], 0)
            np.testing.assert_array_equal(untouched, reference)

    def test_multiline_masks_and_alpha(self):
        reference = np.full((240, 420, 3), 255, np.uint8)
        damaged, region = self.fixture(reference)
        # The group box includes an unrelated line between OCR lines.
        x, y, r, b = cleaning.bounds(region['box'], 420, 240)
        second = dict(region['lines'][0]); second['y'] += 60/240
        damaged[y+60:b+60, x:r] = damaged[y:b, x:r]
        damaged[b+20:b+23, x:r] = 0
        region['lines'].append(second); region['box']['height'] += 60/240
        region['lineCount'] = 2
        rgba = np.dstack((damaged, np.full((240, 420), 200, np.uint8)))
        result, report = self.run_clean(rgba, region)
        self.assertGreater(report['changedPixels'], 200)
        np.testing.assert_array_equal(result[:, :, 3], rgba[:, :, 3])
        np.testing.assert_array_equal(result[b+20:b+23], rgba[b+20:b+23])

    def test_skip_empty_and_ambiguous_regions(self):
        pixels = np.full((100, 100, 3), 255, np.uint8)
        region = {'box': {'x': .1, 'y': .1, 'width': .8, 'height': .8}, 'lineCount': 1}
        result, report = self.run_clean(pixels, region)
        self.assertEqual(report['changedPixels'], 0)
        np.testing.assert_array_equal(result, pixels)
        # A single long drawing stroke should not be treated as a word.
        pixels[45:48, 10:90] = 0
        result, _ = self.run_clean(pixels, region)
        np.testing.assert_array_equal(result, pixels)

    def test_validation(self):
        for box in [dict(x=float('nan'), y=0, width=.1, height=.1),
                    dict(x=-.1, y=0, width=.1, height=.1),
                    dict(x=.9, y=0, width=.2, height=.1)]:
            with self.assertRaises(ValueError):
                cleaning.bounds(box, 100, 100)


if __name__ == '__main__':
    unittest.main()
