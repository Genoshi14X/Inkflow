import importlib.util
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

spec = importlib.util.spec_from_file_location('healing', Path(__file__).resolve().parents[1] / 'scripts/heal-image.py')
healing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(healing)


class HealingTests(unittest.TestCase):
    def test_restore_background_preserve_unmasked_pixels_and_alpha(self):
        for background in (255, 150):
            with self.subTest(background=background), tempfile.TemporaryDirectory(prefix="Inkflow ' ") as folder:
                source = Path(folder) / 'source.png'
                output = Path(folder) / 'result.png'
                pixels = np.full((100, 160, 4), background, np.uint8)
                pixels[:, :, 3] = np.arange(160, dtype=np.uint8)
                pixels[15:25, 35:45, :3] = 0
                Image.fromarray(pixels).save(source)
                healing.heal(source, output, {'diameter': 24, 'points': [{'x': 40/159, 'y': 20/99}]})
                result = np.array(Image.open(output))
                self.assertEqual(result.shape, pixels.shape)
                self.assertGreater(int(result[20, 40, 0]), background - 10)
                self.assertLess(abs(int(result[20, 40, 0]) - background), 10)
                np.testing.assert_array_equal(result[:, :, 3], pixels[:, :, 3])
                np.testing.assert_array_equal(result[40:], pixels[40:])
                np.testing.assert_array_equal(result[:, 70:], pixels[:, 70:])
                # y comes from the top, rather than erasing the mirrored bottom region.
                np.testing.assert_array_equal(result[70:90], pixels[70:90])

    def test_continuous_stroke_and_edges(self):
        with tempfile.TemporaryDirectory() as folder:
            source, output = Path(folder)/'in.png', Path(folder)/'out.png'
            pixels = np.full((80, 120, 3), 255, np.uint8)
            pixels[37:43, 20:101] = 0
            Image.fromarray(pixels).save(source)
            healing.heal(source, output, {'diameter': 14, 'points': [{'x': 17/119, 'y': 40/79}, {'x': 103/119, 'y': 40/79}]})
            result = np.array(Image.open(output))
            self.assertGreater(int(result[40, 60, 0]), 240)
            healing.heal(source, output, {'diameter': 24, 'points': [{'x': 0, 'y': 0}, {'x': 1, 'y': 0}]})
            with Image.open(output) as image:
                self.assertEqual(image.size, (120, 80))

    def test_texture_preserves_screentone_instead_of_blurring(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)/'in.png'
            y, x = np.indices((120, 180))
            gray = np.where((x % 6 - 2)**2 + (y % 6 - 2)**2 < 3, 100, 190).astype(np.uint8)
            reference = np.repeat(gray[:, :, None], 3, axis=2)
            damaged = reference.copy()
            damaged[52:66, 64:116] = 0
            Image.fromarray(damaged).save(source)
            results = {}
            for method in ('texture', 'smooth'):
                output = Path(folder)/(method+'.png')
                healing.heal(source, output, {'diameter': 28, 'points': [{'x': 61/179, 'y': 59/119}, {'x': 119/179, 'y': 59/119}], 'method': method})
                with Image.open(output) as image:
                    results[method] = np.array(image)[:, :, :3]
                np.testing.assert_array_equal(results[method][:30], damaged[:30])
            target = np.s_[50:68, 65:115]
            texture_error = np.abs(results['texture'][target].astype(float)-reference[target]).mean()
            smooth_error = np.abs(results['smooth'][target].astype(float)-reference[target]).mean()
            self.assertLess(texture_error, smooth_error / 3)
            self.assertGreater(results['texture'][target].std(), results['smooth'][target].std() * 2)
            self.assertGreaterEqual(int(results['texture'][target].min()), 100)

    def test_invalid_strokes_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder)/'in.png'
            Image.new('RGB', (20, 20), 'white').save(source)
            for stroke in [
                {'method': 'invalid', 'diameter': 20, 'points': [{'x': .5, 'y': .5}]},
                {'diameter': 0, 'points': [{'x': .5, 'y': .5}]},
                {'diameter': 20, 'points': []},
                {'diameter': 20, 'points': [{'x': float('nan'), 'y': .5}]},
                {'diameter': 20, 'points': [{'x': -1, 'y': .5}]},
                {'diameter': 400, 'points': [{'x': .5, 'y': .5}]},
            ]:
                with self.assertRaises(ValueError):
                    healing.heal(source, Path(folder)/'out.png', stroke)


if __name__ == '__main__':
    unittest.main()
