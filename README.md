# AI Zone Trader: TradingView + MT5 + Telegram

This is a signal-assistance system, not a profit guarantee. It only sends an MT5 order after the Telegram owner presses Confirm.

## Components

- `tradingview/AI_Zone_Trader.pine`: EMA, RSI, MACD, ATR and pivot-zone overlay with webhook alerts.
- `server/server.py`: TradingView receiver, OpenAI + Gemini consensus, Telegram confirmation, and MT5 queue.
- `mt5/AI_Zone_Trader_EA.mq5`: pending orders, risk-based volume, and partial TP closes.

## Security

Revoke every Telegram/OpenAI key previously pasted into chat. Put newly generated keys only in `server/.env`; never use `.env.example` for real secrets and never upload `.env` to Git.

## Setup

1. Copy `server/.env.example` to `server/.env`. Add a new Telegram token, `APP_API_KEY`, `TV_WEBHOOK_SECRET`, `OPENAI_API_KEY_1`, `GEMINI_API_KEY`, and `ANTHROPIC_API_KEY`. Leave `TELEGRAM_CHAT_ID` blank.
2. Run `pip install -r server/requirements.txt`, then run `python server.py`. Alternatively use `docker compose up -d --build`.
3. Publish server port 8080 through a public HTTPS domain, then set `PUBLIC_BASE_URL=https://YOUR_DOMAIN`. Telegram webhook setup is automatic at server startup. TradingView and Telegram webhooks cannot call a private/local address.
4. Set the TradingView alert webhook URL to `https://YOUR_DOMAIN/tradingview/webhook`.
5. Open your bot in Telegram and press **Start**. The first user who sends `/start` is stored as the owner automatically; no Chat ID lookup is required. Do this before sharing the bot link.
6. Add the Pine script to TradingView and create an alert using its `alert()` calls. Set the same `TV_WEBHOOK_SECRET` in the script input.
7. Compile the EA in MetaEditor. In MT5, add `https://YOUR_DOMAIN` to Expert Advisors → Allow WebRequest, attach the EA to a chart, and set its `ApiKey` to `APP_API_KEY`.

## AI rule

With `AI_ENABLED=true`, OpenAI is the technical analyst and Gemini is the risk auditor. When `ANTHROPIC_API_KEY` and `CLAUDE_ENABLED=true` are set, Claude is a third independent risk auditor. Every configured reviewer receives the same EMA, RSI, MACD, ATR, zone, entry, SL, TP and timeframe facts and must approve the signal. The endpoint is `https://api.anthropic.com/v1/messages`. AI is an additional filter, not a promise of accuracy.

## Defaults

TP1 closes 50%, TP2 closes 30%, and TP3 closes the remaining 20%. Default risk is 0.5%; demo forward-test before using real money.
# mql5-mt5
# mql5-mt5
