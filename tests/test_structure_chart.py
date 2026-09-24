import sys
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'server'))

import server


class StructureChartTests(unittest.TestCase):
    def setUp(self):
        self.original_db_path = server.DB_PATH
        self.temp_db = tempfile.NamedTemporaryFile(suffix='.sqlite3', delete=False)
        self.temp_db.close()
        server.DB_PATH = self.temp_db.name
        server.TV_SECRET = 'test-secret'
        server.APP_KEY = 'test-key'
        server.AI_ENABLED = False
        server.TG_TOKEN = 'test-token'
        server.init_db()
        server.telegram = lambda *_args, **_kwargs: None
        server.telegram_send_chart = lambda *_args, **_kwargs: None
        server.claim_owner('1')

    def tearDown(self):
        Path(server.DB_PATH).unlink(missing_ok=True)
        server.DB_PATH = self.original_db_path

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

    def test_migrates_existing_database_and_queues_strategy(self):
        Path(server.DB_PATH).unlink()
        con = sqlite3.connect(server.DB_PATH)
        try:
            con.execute('CREATE TABLE signals (id TEXT PRIMARY KEY, status TEXT)')
            con.commit()
        finally:
            con.close()
        server.init_db()
        con = sqlite3.connect(server.DB_PATH)
        try:
            columns = {row[1] for row in con.execute('PRAGMA table_info(signals)')}
        finally:
            con.close()
        self.assertTrue({'pattern', 'timeframe', 'strategy', 'expires_at'} <= columns)
        Path(server.DB_PATH).unlink()
        server.init_db()
        server.claim_owner('1')

        client = server.app.test_client()
        response = client.post('/tradingview/webhook', json={
            'secret': 'test-secret', 'symbol': 'EURUSD', 'side': 'BUY',
            'order_type': 'LIMIT', 'strategy': 'SCALP', 'entry': 1.0900,
            'zone_low': 1.0890, 'zone_high': 1.0910, 'sl': 1.0880,
            'tp1': 1.0925, 'tp2': 1.0940, 'tp3': 1.0960, 'risk_pct': 0.5,
        })
        self.assertEqual(response.status_code, 200)
        signal_id = response.get_json()['id']
        with server.db() as con:
            con.execute("UPDATE signals SET status='approved' WHERE id=?", (signal_id,))
        command = client.get('/mt5/next', headers={'X-Api-Key': 'test-key'}).get_data(as_text=True)
        self.assertTrue(command.endswith('|SCALP'), command)
        dashboard = client.get('/dashboard', headers={'X-Api-Key': 'test-key'})
        self.assertEqual(dashboard.status_code, 200)

    def test_rejects_invalid_risk_reward(self):
        client = server.app.test_client()
        response = client.post('/tradingview/webhook', json={
            'secret': 'test-secret', 'symbol': 'EURUSD', 'side': 'BUY',
            'entry': 1.0900, 'zone_low': 1.0890, 'zone_high': 1.0910,
            'sl': 1.0880, 'tp1': 1.0910, 'tp2': 1.0920, 'tp3': 1.0930,
        })
        self.assertEqual(response.status_code, 400)
        self.assertIn('risk/reward', response.get_json()['error'])

    def test_claude_review_uses_official_messages_endpoint(self):
        class FakeResponse:
            def raise_for_status(self):
                return None

            def json(self):
                return {'content': [{'type': 'text', 'text': '{"approve":true,"confidence":84,"reason":"trend aligned","risk_flag":"none"}'}]}

        server.CLAUDE_KEY = 'claude-test-key'
        server.CLAUDE_API_URL = 'https://api.anthropic.com/v1/messages'
        signal = {'symbol': 'EURUSD', 'side': 'BUY', 'entry': 1.09, 'sl': 1.088, 'tp1': 1.093}
        with patch.object(server.requests, 'post', return_value=FakeResponse()) as post:
            verdict = server.claude_review(signal)
        self.assertTrue(verdict['approve'])
        self.assertEqual(verdict['confidence'], 84)
        self.assertEqual(post.call_args.args[0], 'https://api.anthropic.com/v1/messages')
        self.assertEqual(post.call_args.kwargs['headers']['anthropic-version'], '2023-06-01')


if __name__ == '__main__':
    unittest.main()
