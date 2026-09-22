import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))

import server


class StructureChartTests(unittest.TestCase):
    def test_generate_trade_visualization_returns_png_bytes(self):
        signal = {
            'symbol': 'EURUSD',
            'side': 'BUY',
            'entry': 1.0925,
            'zone_low': 1.0890,
            'zone_high': 1.0940,
            'sl': 1.0850,
            'tp1': 1.0995,
            'tp2': 1.1045,
            'tp3': 1.1090,
            'risk_pct': 0.5,
            'confidence': 82,
            'analysis': 'Trend + W structure + zone confluence',
            'timeframe': 'H1',
        }

        image = server.generate_trade_visualization(signal)
        self.assertIsInstance(image, (bytes, bytearray))
        self.assertTrue(image.startswith(b'\x89PNG'))

    def test_structure_label_for_buy_signal_is_w_pattern(self):
        signal = {'side': 'BUY'}
        self.assertIn('W', server.structure_label(signal))


if __name__ == '__main__':
    unittest.main()
