"""TradingView webhook -> Telegram confirmation -> MT5 command queue."""
import json
import os
import secrets
import sqlite3
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import requests
from dotenv import load_dotenv
from flask import Flask, Response, abort, jsonify, request

load_dotenv()
app = Flask(__name__)
DB_PATH = os.path.join(os.path.dirname(__file__), "signals.sqlite3")
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
OWNER_CHAT_ID = str(os.environ.get("TELEGRAM_CHAT_ID", ""))
APP_KEY = os.environ.get("APP_API_KEY", "")
TV_SECRET = os.environ.get("TV_WEBHOOK_SECRET", "")
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "").rstrip("/")
OPENAI_KEY = os.environ.get("OPENAI_API_KEY_1", "")
GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "")
AI_ENABLED = os.getenv("AI_ENABLED", "false").lower() == "true"
AI_REQUIRED = os.getenv("AI_REQUIRED", "true").lower() == "true"
AI_MIN_CONFIDENCE = int(os.getenv("AI_MIN_CONFIDENCE", "70"))
OPENAI_MODEL = os.getenv("OPENAI_MODEL_1", "gpt-5-mini")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
VERDICT_SCHEMA = {"type": "object", "additionalProperties": False, "properties": {
    "approve": {"type": "boolean"}, "confidence": {"type": "integer", "minimum": 0, "maximum": 100},
    "reason": {"type": "string", "maxLength": 180}, "risk_flag": {"type": "string", "maxLength": 120},
}, "required": ["approve", "confidence", "reason", "risk_flag"]}

def db():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    return con

def init_db():
    with db() as con:
        con.execute("""CREATE TABLE IF NOT EXISTS signals (
          id TEXT PRIMARY KEY, created_at TEXT, symbol TEXT, side TEXT, order_type TEXT,
          entry REAL, zone_low REAL, zone_high REAL, sl REAL, tp1 REAL, tp2 REAL, tp3 REAL,
          risk_pct REAL, confidence INTEGER, analysis TEXT, status TEXT DEFAULT 'pending')""")
        con.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        if OWNER_CHAT_ID:
            con.execute("INSERT OR IGNORE INTO settings(key,value) VALUES ('owner_chat_id',?)", (OWNER_CHAT_ID,))

def telegram(method, payload):
    if not TG_TOKEN:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not configured")
    return requests.post(f"https://api.telegram.org/bot{TG_TOKEN}/{method}", json=payload, timeout=12)

def configure_telegram_webhook():
    if not TG_TOKEN or not PUBLIC_BASE_URL:
        return
    response = telegram("setWebhook", {"url": PUBLIC_BASE_URL + "/telegram/webhook", "allowed_updates": ["message", "callback_query"]})
    if not response.ok:
        print("Telegram webhook setup failed:", response.text[:250])

def require_owner(chat_id):
    return bool(owner_chat_id()) and str(chat_id) == owner_chat_id()

def owner_chat_id():
    with db() as con:
        row = con.execute("SELECT value FROM settings WHERE key='owner_chat_id'").fetchone()
    return row["value"] if row else ""

def claim_owner(chat_id):
    with db() as con:
        con.execute("INSERT OR IGNORE INTO settings(key,value) VALUES ('owner_chat_id',?)", (str(chat_id),))
        row = con.execute("SELECT value FROM settings WHERE key='owner_chat_id'").fetchone()
    return row["value"] == str(chat_id)

def _response_text(body):
    for item in body.get("output", []):
        for content in item.get("content", []):
            if content.get("type") == "output_text":
                return content.get("text", "")
    raise ValueError("OpenAI response contained no output text")

def ai_review(signal, role, key, model):
    facts = {k: signal.get(k) for k in ("symbol", "side", "order_type", "entry", "zone_low", "zone_high", "sl", "tp1", "tp2", "tp3", "confidence", "timeframe", "price", "ema_fast", "ema_slow", "rsi", "macd", "macd_signal", "atr")}
    instructions = (f"You are the {role} in a two-agent trade-review system. Assess only supplied indicator facts. "
                    "Do not invent prices/history or claim certainty. Reject inconsistent trend, SL, entry-zone or reward/risk logic.")
    payload = {"model": model, "store": False, "instructions": instructions, "input": json.dumps(facts, separators=(",", ":")),
               "text": {"format": {"type": "json_schema", "name": "trade_review", "strict": True, "schema": VERDICT_SCHEMA}}}
    response = requests.post("https://api.openai.com/v1/responses", headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"}, json=payload, timeout=25)
    response.raise_for_status()
    return json.loads(_response_text(response.json()))

def gemini_review(signal):
    facts = {k: signal.get(k) for k in ("symbol", "side", "order_type", "entry", "zone_low", "zone_high", "sl", "tp1", "tp2", "tp3", "confidence", "timeframe", "price", "ema_fast", "ema_slow", "rsi", "macd", "macd_signal", "atr")}
    prompt = ("You are the risk auditor in a trade-review system. Assess only supplied indicator facts. Do not invent history or claim certainty. Reject inconsistent trend, SL, entry-zone or reward/risk logic. Return JSON.\n" + json.dumps(facts, separators=(",", ":")))
    payload = {"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"responseMimeType": "application/json", "responseJsonSchema": VERDICT_SCHEMA}}
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
    response = requests.post(url, headers={"x-goog-api-key": GEMINI_KEY, "Content-Type": "application/json"}, json=payload, timeout=25)
    response.raise_for_status()
    return json.loads(response.json()["candidates"][0]["content"]["parts"][0]["text"])

def consensus(signal):
    """Both roles must approve; unavailable AI fails closed when AI_REQUIRED is true."""
    if not AI_ENABLED: return True, int(signal.get("confidence", 0)), "Rules-only: AI disabled"
    if not OPENAI_KEY or not GEMINI_KEY: return (not AI_REQUIRED), 0, "AI blocked: OpenAI and Gemini keys are required"
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            openai = pool.submit(ai_review, signal, "technical analyst", OPENAI_KEY, OPENAI_MODEL)
            gemini = pool.submit(gemini_review, signal)
            reviews = [openai.result(), gemini.result()]
    except Exception as exc: return (not AI_REQUIRED), 0, "AI unavailable: " + str(exc)[:100]
    ai_score = round(sum(r["confidence"] for r in reviews) / len(reviews))
    score = round((int(signal.get("confidence", 0)) + ai_score) / 2)
    details = " | ".join(r["reason"] for r in reviews)
    flags = "; ".join(r["risk_flag"] for r in reviews if r["risk_flag"].lower() != "none")
    return all(r["approve"] for r in reviews) and score >= AI_MIN_CONFIDENCE, score, (details + (" | Risk: " + flags if flags else ""))[:450]

def fmt(s):
    return (f"{'🟢' if s['side'] == 'BUY' else '🔴'} <b>{s['symbol']} | {s['side']} {s['order_type']}</b>\n"
            f"AI / rules confidence: <b>{s['confidence']}%</b>\n\n"
            f"Entry zone: <code>{s['zone_low']:.5f} – {s['zone_high']:.5f}</code>\n"
            f"Order entry: <code>{s['entry']:.5f}</code>\n"
            f"Stop Loss: <code>{s['sl']:.5f}</code>\n"
            f"TP1 (50%): <code>{s['tp1']:.5f}</code>\n"
            f"TP2 (30%): <code>{s['tp2']:.5f}</code>\n"
            f"TP3 (20%): <code>{s['tp3']:.5f}</code>\n\n"
            f"Risk: <b>{s['risk_pct']:.2f}%</b> | expires when market conditions change\n"
            f"Reason: {s['analysis']}")

@app.post("/tradingview/webhook")
def tradingview_webhook():
    data = request.get_json(silent=True) or {}
    if not TV_SECRET or not secrets.compare_digest(str(data.get("secret", "")), TV_SECRET):
        abort(401)
    required = ("symbol", "side", "entry", "zone_low", "zone_high", "sl", "tp1", "tp2", "tp3")
    if any(k not in data for k in required) or data["side"] not in ("BUY", "SELL"):
        return jsonify(error="invalid payload"), 400
    signal_id = secrets.token_urlsafe(10)
    signal = {
        "id": signal_id, "created_at": datetime.now(timezone.utc).isoformat(),
        "symbol": str(data["symbol"]), "side": data["side"],
        "order_type": data.get("order_type", "LIMIT"), "entry": float(data["entry"]),
        "zone_low": float(data["zone_low"]), "zone_high": float(data["zone_high"]),
        "sl": float(data["sl"]), "tp1": float(data["tp1"]), "tp2": float(data["tp2"]), "tp3": float(data["tp3"]),
        "risk_pct": float(data.get("risk_pct", os.getenv("DEFAULT_RISK_PERCENT", "0.5"))),
        "confidence": int(data.get("confidence", 0)),
        "analysis": str(data.get("analysis", "Trend + RSI + MACD + zone alignment")),
        "timeframe": str(data.get("timeframe", "")), "price": data.get("price"), "ema_fast": data.get("ema_fast"),
        "ema_slow": data.get("ema_slow"), "rsi": data.get("rsi"), "macd": data.get("macd"),
        "macd_signal": data.get("macd_signal"), "atr": data.get("atr"),
    }
    accepted, final_confidence, review = consensus(signal)
    if not accepted: return jsonify(ok=True, sent=False, reason="Signal filtered: " + review)
    signal["confidence"], signal["analysis"] = final_confidence, review
    with db() as con:
        con.execute("INSERT INTO signals VALUES (:id,:created_at,:symbol,:side,:order_type,:entry,:zone_low,:zone_high,:sl,:tp1,:tp2,:tp3,:risk_pct,:confidence,:analysis,'pending')", signal)
    owner = owner_chat_id()
    if not owner: return jsonify(error="Telegram owner missing: send /start to the bot first"), 503
    keyboard = {"inline_keyboard": [[
        {"text": "✅ Tasdiqlash", "callback_data": f"approve:{signal_id}"},
        {"text": "❌ Rad etish", "callback_data": f"reject:{signal_id}"}],
        [{"text": "📊 Batafsil tahlil", "callback_data": f"detail:{signal_id}"}]]}
    telegram("sendMessage", {"chat_id": owner, "text": fmt(signal), "parse_mode": "HTML", "reply_markup": keyboard})
    return jsonify(ok=True, id=signal_id)

@app.post("/telegram/webhook")
def telegram_webhook():
    update = request.get_json(silent=True) or {}
    message = update.get("message") or {}
    if message.get("text", "").strip().startswith("/start"):
        chat_id = message.get("chat", {}).get("id")
        if chat_id and claim_owner(chat_id):
            telegram("sendMessage", {"chat_id": chat_id, "text": "Bot connected. You are the only user who can confirm signals."})
        elif chat_id:
            telegram("sendMessage", {"chat_id": chat_id, "text": "This bot is already linked to another owner."})
        return "ok"
    query = update.get("callback_query")
    if not query or not require_owner(query.get("message", {}).get("chat", {}).get("id")):
        return "ok"
    action, signal_id = query.get("data", ":").split(":", 1)
    with db() as con:
        row = con.execute("SELECT * FROM signals WHERE id=?", (signal_id,)).fetchone()
        if not row:
            telegram("answerCallbackQuery", {"callback_query_id": query["id"], "text": "Signal topilmadi"})
            return "ok"
        signal = dict(row)
        status = "approved" if action == "approve" else "rejected" if action == "reject" else signal["status"]
        if action in ("approve", "reject") and signal["status"] == "pending":
            con.execute("UPDATE signals SET status=? WHERE id=?", (status, signal_id))
        msg = fmt(signal) if action == "detail" else ("✅ Tasdiqlandi. MT5 EA orderni tekshiradi." if action == "approve" else "❌ Signal rad etildi.")
    telegram("answerCallbackQuery", {"callback_query_id": query["id"], "text": "Qabul qilindi"})
    telegram("sendMessage", {"chat_id": owner_chat_id(), "text": msg, "parse_mode": "HTML"})
    return "ok"

@app.get("/mt5/next")
def mt5_next():
    if not APP_KEY or not secrets.compare_digest(request.headers.get("X-Api-Key", ""), APP_KEY):
        abort(401)
    with db() as con:
        row = con.execute("SELECT * FROM signals WHERE status='approved' ORDER BY created_at LIMIT 1").fetchone()
        if not row:
            return Response("NONE", mimetype="text/plain")
        s = dict(row)
    # Delimiter format keeps MQL parsing dependency-free.
    return Response("OPEN|{id}|{symbol}|{side}|{order_type}|{entry}|{sl}|{tp1}|{tp2}|{tp3}|{risk_pct}".format(**s), mimetype="text/plain")

@app.post("/mt5/ack/<signal_id>")
def mt5_ack(signal_id):
    if not APP_KEY or not secrets.compare_digest(request.headers.get("X-Api-Key", ""), APP_KEY):
        abort(401)
    with db() as con:
        con.execute("UPDATE signals SET status='sent_to_mt5' WHERE id=? AND status='approved'", (signal_id,))
    return jsonify(ok=True)

@app.get("/health")
def health():
    return jsonify(ok=True, telegram_configured=bool(TG_TOKEN), owner_configured=bool(owner_chat_id()), openai_configured=bool(OPENAI_KEY), gemini_configured=bool(GEMINI_KEY))

if __name__ == "__main__":
    init_db()
    configure_telegram_webhook()
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
