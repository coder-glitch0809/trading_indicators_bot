"""TradingView webhook -> Telegram confirmation -> MT5 command queue."""
import io
import json
import os
import secrets
import sqlite3
import tempfile
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone

import requests
from dotenv import load_dotenv
from flask import Flask, Response, abort, jsonify, request

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except Exception:  # pragma: no cover - optional dependency handled at runtime
    plt = None

load_dotenv()
app = Flask(__name__)
# Vercel's deployment filesystem is read-only. Files in /tmp are writable for
# the lifetime of a warm function instance; local development keeps its DB here.
if os.environ.get("VERCEL"):
    DB_PATH = os.path.join("/tmp" if os.name != "nt" else tempfile.gettempdir(), "signals.sqlite3")
else:
    DB_PATH = os.path.join(os.path.dirname(__file__), "signals.sqlite3")
TG_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
OWNER_CHAT_ID = str(os.environ.get("TELEGRAM_CHAT_ID", ""))
APP_KEY = os.environ.get("APP_API_KEY", "")
TV_SECRET = os.environ.get("TV_WEBHOOK_SECRET", "")
PUBLIC_BASE_URL = os.environ.get("PUBLIC_BASE_URL", "").rstrip("/")
OPENAI_KEY = os.environ.get("OPENAI_API_KEY_1", "")
GEMINI_KEY = os.environ.get("GEMINI_API_KEY", "")
CLAUDE_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
AI_ENABLED = os.getenv("AI_ENABLED", "false").lower() == "true"
AI_REQUIRED = os.getenv("AI_REQUIRED", "true").lower() == "true"
CLAUDE_ENABLED = os.getenv("CLAUDE_ENABLED", "true").lower() == "true"
AI_MIN_CONFIDENCE = int(os.getenv("AI_MIN_CONFIDENCE", "70"))
SIGNAL_TTL_MINUTES = max(1, int(os.getenv("SIGNAL_TTL_MINUTES", "30")))
MIN_RISK_REWARD = max(0.1, float(os.getenv("MIN_RISK_REWARD", "1.2")))
OPENAI_MODEL = os.getenv("OPENAI_MODEL_1", "gpt-5-mini")
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
CLAUDE_MODEL = os.getenv("CLAUDE_MODEL", "claude-sonnet-4-20250514")
CLAUDE_API_URL = os.getenv("CLAUDE_API_URL", "https://api.anthropic.com/v1/messages")
VERDICT_SCHEMA = {"type": "object", "additionalProperties": False, "properties": {
    "approve": {"type": "boolean"}, "confidence": {"type": "integer", "minimum": 0, "maximum": 100},
    "reason": {"type": "string", "maxLength": 180}, "risk_flag": {"type": "string", "maxLength": 120},
}, "required": ["approve", "confidence", "reason", "risk_flag"]}

@contextmanager
def db():
    con = sqlite3.connect(DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        yield con
        con.commit()
    finally:
        con.close()

def init_db():
    with db() as con:
        con.execute("""CREATE TABLE IF NOT EXISTS signals (
          id TEXT PRIMARY KEY, created_at TEXT, symbol TEXT, side TEXT, order_type TEXT,
          entry REAL, zone_low REAL, zone_high REAL, sl REAL, tp1 REAL, tp2 REAL, tp3 REAL,
          risk_pct REAL, confidence INTEGER, pattern TEXT, timeframe TEXT, strategy TEXT,
          expires_at TEXT, analysis TEXT, status TEXT DEFAULT 'pending')""")
        con.execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        con.execute("""CREATE TABLE IF NOT EXISTS signal_events (
          id INTEGER PRIMARY KEY AUTOINCREMENT, signal_id TEXT, created_at TEXT,
          event TEXT NOT NULL, detail TEXT NOT NULL DEFAULT '')""")
        columns = {row["name"] for row in con.execute("PRAGMA table_info(signals)")}
        for name, definition in (("pattern", "TEXT"), ("timeframe", "TEXT"),
                                 ("strategy", "TEXT"), ("expires_at", "TEXT")):
            if name not in columns:
                con.execute(f"ALTER TABLE signals ADD COLUMN {name} {definition}")
        if OWNER_CHAT_ID:
            con.execute("INSERT OR IGNORE INTO settings(key,value) VALUES ('owner_chat_id',?)", (OWNER_CHAT_ID,))

def now_iso():
    return datetime.now(timezone.utc).isoformat()

def log_event(con, signal_id, event, detail=""):
    con.execute("INSERT INTO signal_events(signal_id,created_at,event,detail) VALUES (?,?,?,?)",
                (signal_id, now_iso(), event, str(detail)[:500]))

def setting(key, default=""):
    with db() as con:
        row = con.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return row["value"] if row else default

def set_setting(key, value):
    with db() as con:
        con.execute("INSERT INTO settings(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    (key, str(value)))

def telegram(method, payload):
    if not TG_TOKEN:
        raise RuntimeError("TELEGRAM_BOT_TOKEN is not configured")
    return requests.post(f"https://api.telegram.org/bot{TG_TOKEN}/{method}", json=payload, timeout=12)

def configure_telegram_webhook():
    if not TG_TOKEN or not PUBLIC_BASE_URL:
        return
    try:
        response = telegram("setWebhook", {"url": PUBLIC_BASE_URL + "/telegram/webhook", "allowed_updates": ["message", "callback_query"]})
        if not response.ok:
            print("Telegram webhook setup failed:", response.text[:250])
    except requests.RequestException as exc:
        print("Telegram webhook setup unavailable:", str(exc)[:160])

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

def signal_facts(signal):
    return {k: signal.get(k) for k in ("symbol", "side", "order_type", "entry", "zone_low", "zone_high",
                                       "sl", "tp1", "tp2", "tp3", "confidence", "timeframe", "price",
                                       "ema_fast", "ema_slow", "rsi", "macd", "macd_signal", "atr")}

def parse_verdict(text):
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()
    verdict = json.loads(text)
    if not isinstance(verdict.get("approve"), bool) or not isinstance(verdict.get("confidence"), int):
        raise ValueError("AI verdict has an invalid schema")
    if not 0 <= verdict["confidence"] <= 100:
        raise ValueError("AI confidence is outside 0-100")
    for key in ("reason", "risk_flag"):
        if not isinstance(verdict.get(key), str):
            raise ValueError("AI verdict has an invalid schema")
    return verdict

def ai_review(signal, role, key, model):
    facts = signal_facts(signal)
    instructions = (f"You are the {role} in a multi-agent trade-review system. Assess only supplied indicator facts. "
                    "Do not invent prices/history or claim certainty. Reject inconsistent trend, SL, entry-zone or reward/risk logic.")
    payload = {"model": model, "store": False, "instructions": instructions, "input": json.dumps(facts, separators=(",", ":")),
               "text": {"format": {"type": "json_schema", "name": "trade_review", "strict": True, "schema": VERDICT_SCHEMA}}}
    response = requests.post("https://api.openai.com/v1/responses", headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"}, json=payload, timeout=25)
    response.raise_for_status()
    return parse_verdict(_response_text(response.json()))

def gemini_review(signal):
    facts = signal_facts(signal)
    prompt = ("You are the risk auditor in a trade-review system. Assess only supplied indicator facts. Do not invent history or claim certainty. Reject inconsistent trend, SL, entry-zone or reward/risk logic. Return JSON.\n" + json.dumps(facts, separators=(",", ":")))
    payload = {"contents": [{"parts": [{"text": prompt}]}], "generationConfig": {"responseMimeType": "application/json", "responseJsonSchema": VERDICT_SCHEMA}}
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
    response = requests.post(url, headers={"x-goog-api-key": GEMINI_KEY, "Content-Type": "application/json"}, json=payload, timeout=25)
    response.raise_for_status()
    return parse_verdict(response.json()["candidates"][0]["content"]["parts"][0]["text"])

def claude_review(signal):
    facts = signal_facts(signal)
    system = ("You are the independent risk auditor in a multi-agent trade-review system. "
              "Assess only supplied indicator facts. Do not invent prices, history, news, or certainty. "
              "Reject inconsistent trend, SL, entry-zone or reward/risk logic. Return only valid JSON matching "
              '{"approve":boolean,"confidence":integer,"reason":string,"risk_flag":string}.')
    payload = {
        "model": CLAUDE_MODEL,
        "max_tokens": 300,
        "temperature": 0,
        "system": system,
        "messages": [{"role": "user", "content": json.dumps(facts, separators=(",", ":"))}],
    }
    headers = {"x-api-key": CLAUDE_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json"}
    response = requests.post(CLAUDE_API_URL, headers=headers, json=payload, timeout=25)
    response.raise_for_status()
    return parse_verdict(response.json()["content"][0]["text"])

def consensus(signal):
    """Every configured AI reviewer must approve; required AI failures fail closed."""
    if not AI_ENABLED: return True, int(signal.get("confidence", 0)), "Rules-only: AI disabled"
    if not OPENAI_KEY or not GEMINI_KEY: return (not AI_REQUIRED), 0, "AI blocked: OpenAI and Gemini keys are required"
    try:
        with ThreadPoolExecutor(max_workers=3) as pool:
            openai = pool.submit(ai_review, signal, "technical analyst", OPENAI_KEY, OPENAI_MODEL)
            gemini = pool.submit(gemini_review, signal)
            futures = [openai, gemini]
            if CLAUDE_ENABLED and CLAUDE_KEY:
                futures.append(pool.submit(claude_review, signal))
            reviews = [future.result() for future in futures]
    except Exception as exc: return (not AI_REQUIRED), 0, "AI unavailable: " + str(exc)[:100]
    ai_score = round(sum(r["confidence"] for r in reviews) / len(reviews))
    score = round((int(signal.get("confidence", 0)) + ai_score) / 2)
    details = " | ".join(r["reason"] for r in reviews)
    flags = "; ".join(r["risk_flag"] for r in reviews if r["risk_flag"].lower() != "none")
    return all(r["approve"] for r in reviews) and score >= AI_MIN_CONFIDENCE, score, (details + (" | Risk: " + flags if flags else ""))[:450]

def structure_label(signal):
    pattern = str(signal.get("pattern", "")).upper().strip()
    if pattern in {"W", "DOUBLE_BOTTOM", "DOUBLE BOTTOM", "W_PATTERN", "W-PATTERN"}:
        return "W"
    if pattern in {"M", "DOUBLE_TOP", "DOUBLE TOP", "M_PATTERN", "M-PATTERN", "HEAD_AND_SHOULDERS", "HEAD AND SHOULDERS"}:
        return "M"
    if pattern in {"V", "V_PATTERN", "V-PATTERN"}:
        return "V"
    if pattern in {"TRIANGLE", "ASCENDING_TRIANGLE", "DESCENDING_TRIANGLE"}:
        return "TRIANGLE"
    side = str(signal.get("side", "")).upper()
    if side == "BUY":
        return "W"
    if side == "SELL":
        return "M"
    return "TREND"


def generate_trade_visualization(signal):
    if plt is None:
        raise RuntimeError("matplotlib is required to generate trade charts")

    side = str(signal.get("side", "BUY")).upper()
    entry = float(signal.get("entry", 0.0) or 0.0)
    zone_low = float(signal.get("zone_low", entry) or entry)
    zone_high = float(signal.get("zone_high", entry) or entry)
    sl = float(signal.get("sl", min(zone_low, entry) - abs(zone_high - zone_low)) or 0.0)
    tp1 = float(signal.get("tp1", entry) or entry)
    tp2 = float(signal.get("tp2", entry) or entry)
    tp3 = float(signal.get("tp3", entry) or entry)
    symbol = str(signal.get("symbol", "PAIR"))
    confidence = int(signal.get("confidence", 0) or 0)
    structure = structure_label(signal)
    pattern_name = structure if structure in {"W", "M", "V", "TRIANGLE"} else "TREND"

    price_min = min(zone_low, entry, sl, tp1, tp2, tp3)
    price_max = max(zone_high, entry, sl, tp1, tp2, tp3)
    padding = max((price_max - price_min) * 0.22, 0.0005)
    price_min -= padding
    price_max += padding

    fig, ax = plt.subplots(figsize=(8.2, 5.2))
    fig.patch.set_facecolor("#0d1117")
    ax.set_facecolor("#111827")

    zone_x = [0.9, 4.8]
    ax.axvspan(zone_x[0], zone_x[1], ymin=0, ymax=1, facecolor="#2dd4bf", alpha=0.12)

    if side == "BUY":
        x = [0.0, 1.2, 2.2, 3.2, 4.6]
        y = [zone_high, zone_low + ((zone_high - zone_low) * 0.80), zone_high, entry, zone_high + ((price_max - price_min) * 0.04)]
        ax.plot(x, y, color="#22c55e", linewidth=2.5)
        ax.scatter([2.2], [entry], color="#4ade80", s=80, zorder=5)
        ax.text(3.2, entry + (price_max - price_min) * 0.02, "W", fontsize=15, fontweight="bold", color="#86efac")
    else:
        x = [0.0, 1.2, 2.2, 3.2, 4.6]
        y = [zone_low, zone_high - ((zone_high - zone_low) * 0.80), zone_low, entry, zone_low - ((price_max - price_min) * 0.04)]
        ax.plot(x, y, color="#f87171", linewidth=2.5)
        ax.scatter([2.2], [entry], color="#fca5a5", s=80, zorder=5)
        ax.text(3.2, entry - (price_max - price_min) * 0.02, "M", fontsize=15, fontweight="bold", color="#fca5a5")

    ax.axhline(entry, color="#a5f3fc", linestyle="--", linewidth=1.5, alpha=0.9, label="Entry")
    ax.axhline(sl, color="#fca5a5", linestyle="-.", linewidth=1.3, label="SL")
    ax.axhline(tp1, color="#86efac", linestyle=":", linewidth=1.3, label="TP1")
    ax.axhline(tp2, color="#bef264", linestyle=":", linewidth=1.3, label="TP2")
    ax.axhline(tp3, color="#fcd34d", linestyle=":", linewidth=1.3, label="TP3")

    ax.fill_between([0.9, 4.8], zone_low, zone_high, color="#60a5fa", alpha=0.18)
    ax.set_ylim(price_min, price_max)
    ax.set_xlim(0.0, 5.0)
    ax.set_xticks([])
    ax.grid(True, alpha=0.18)
    ax.set_title(f"{symbol} | {side} | {pattern_name} pattern | {confidence}% confidence", color="#e2e8f0", fontsize=12)
    ax.set_ylabel("Price", color="#cbd5e1")
    ax.tick_params(axis='y', colors="#cbd5e1")
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.spines["left"].set_color("#475569")
    ax.spines["bottom"].set_color("#475569")

    legend = ax.legend(loc="upper left", frameon=False, fontsize=8)
    for text in legend.get_texts():
        text.set_color("#e2e8f0")

    ax.text(0.10, 0.02, f"Zone: {zone_low:.5f} – {zone_high:.5f}", transform=ax.transAxes, color="#cbd5e1", fontsize=8)
    ax.text(0.55, 0.02, f"Trend = {signal.get('timeframe', 'H1')}", transform=ax.transAxes, color="#cbd5e1", fontsize=8)

    buf = io.BytesIO()
    fig.tight_layout()
    fig.savefig(buf, format="png", dpi=180)
    plt.close(fig)
    return buf.getvalue()


def telegram_send_chart(chat_id, signal):
    if not TG_TOKEN:
        return None
    try:
        chart = generate_trade_visualization(signal)
    except RuntimeError:
        return None
    payload = {
        "chat_id": chat_id,
        "caption": (
            f"{signal.get('symbol', 'PAIR')} | {signal.get('side', 'BUY')} | {structure_label(signal)} pattern\n"
            f"Timeframe: {signal.get('timeframe', 'N/A')}\n"
            f"Entry: {float(signal.get('entry') or 0):.5f}\n"
            f"Zone: {float(signal.get('zone_low') or 0):.5f} - {float(signal.get('zone_high') or 0):.5f}\n"
            f"SL/TP: {float(signal.get('sl') or 0):.5f} / {float(signal.get('tp3') or 0):.5f}"
        )
    }
    files = {"photo": ("trade_structure.png", chart, "image/png")}
    return requests.post(f"https://api.telegram.org/bot{TG_TOKEN}/sendPhoto", data=payload, files=files, timeout=20)


def send_self_test_message():
    owner = owner_chat_id()
    if not owner or not TG_TOKEN:
        return {"ok": False, "reason": "telegram_owner_or_token_missing"}
    sample = {
        "symbol": "XAUUSD",
        "side": "BUY",
        "pattern": "W",
        "entry": 2348.12,
        "zone_low": 2344.60,
        "zone_high": 2352.18,
        "sl": 2339.20,
        "tp1": 2356.00,
        "tp2": 2360.50,
        "tp3": 2364.20,
        "risk_pct": 0.50,
        "confidence": 82,
        "analysis": "Self-test: monitor online, trend filter active, retest valid, risk gate armed.",
        "timeframe": "M15",
        "order_type": "LIMIT"
    }
    telegram("sendMessage", {
        "chat_id": owner,
        "text": "✅ Bot self-test OK. Monitor alive. Trend+retest+risk gate active.\n\n" + fmt(sample),
        "parse_mode": "HTML",
    })
    telegram_send_chart(owner, sample)
    return {"ok": True, "owner": owner, "message": "self-test-sent"}


def fmt(s):
    pattern = structure_label(s)
    timeframe = str(s.get("timeframe", "N/A")).upper()
    return (f"{'🟢' if s['side'] == 'BUY' else '🔴'} <b>{s['symbol']} | {s['side']} {s['order_type']}</b>\n"
            f"Structure: <b>{pattern}</b> | Timeframe: <b>{timeframe}</b>\n"
            f"AI / rules confidence: <b>{s['confidence']}%</b>\n\n"
            f"Entry zone: <code>{s['zone_low']:.5f} – {s['zone_high']:.5f}</code>\n"
            f"Order entry: <code>{s['entry']:.5f}</code>\n"
            f"Stop Loss: <code>{s['sl']:.5f}</code>\n"
            f"TP1 (50%): <code>{s['tp1']:.5f}</code>\n"
            f"TP2 (30%): <code>{s['tp2']:.5f}</code>\n"
            f"TP3 (20%): <code>{s['tp3']:.5f}</code>\n\n"
            f"Risk: <b>{s['risk_pct']:.2f}%</b> | expires when market conditions change\n"
            f"Reason: {s['analysis']}")

def validate_trade(signal):
    entry, sl, tp1, tp2, tp3 = (signal[key] for key in ("entry", "sl", "tp1", "tp2", "tp3"))
    zone_low, zone_high = signal["zone_low"], signal["zone_high"]
    if zone_low > zone_high:
        return "zone_low must not exceed zone_high"
    if not zone_low <= entry <= zone_high:
        return "entry must be inside the supplied zone"
    risk = abs(entry - sl)
    if risk <= 0:
        return "stop loss must differ from entry"
    if signal["side"] == "BUY":
        if not (sl < entry < tp1 <= tp2 <= tp3):
            return "BUY requires SL < entry < TP1 <= TP2 <= TP3"
        reward = tp1 - entry
    else:
        if not (sl > entry > tp1 >= tp2 >= tp3):
            return "SELL requires SL > entry > TP1 >= TP2 >= TP3"
        reward = entry - tp1
    if reward / risk < MIN_RISK_REWARD:
        return f"TP1 risk/reward must be at least {MIN_RISK_REWARD:g}"
    if not 0 < signal["risk_pct"] <= 100:
        return "risk_pct must be between 0 and 100"
    return ""

def expire_signals(con):
    con.execute("UPDATE signals SET status='expired' WHERE status IN ('pending','approved') "
                "AND expires_at IS NOT NULL AND expires_at <= ?", (now_iso(),))

def news_blocked():
    value = setting("news_block_until", "")
    if not value:
        return False
    try:
        return datetime.fromisoformat(value) > datetime.now(timezone.utc)
    except ValueError:
        return False

@app.post("/tradingview/webhook")
def tradingview_webhook():
    data = request.get_json(silent=True) or {}
    if not TV_SECRET or not secrets.compare_digest(str(data.get("secret", "")), TV_SECRET):
        abort(401)
    required = ("symbol", "side", "entry", "zone_low", "zone_high", "sl", "tp1", "tp2", "tp3")
    if any(k not in data for k in required) or data["side"] not in ("BUY", "SELL"):
        return jsonify(error="invalid payload"), 400
    signal_id = secrets.token_urlsafe(10)
    try:
        risk_pct = float(data.get("risk_pct", setting("risk_pct", os.getenv("DEFAULT_RISK_PERCENT", "0.5"))))
        signal = {
        "id": signal_id, "created_at": now_iso(),
        "symbol": str(data["symbol"]), "side": data["side"],
        "order_type": data.get("order_type", "LIMIT"), "entry": float(data["entry"]),
        "zone_low": float(data["zone_low"]), "zone_high": float(data["zone_high"]),
        "sl": float(data["sl"]), "tp1": float(data["tp1"]), "tp2": float(data["tp2"]), "tp3": float(data["tp3"]),
        "risk_pct": risk_pct,
        "confidence": int(data.get("confidence", 0)),
        "pattern": str(data.get("pattern", structure_label({"side": data.get("side", "BUY")}))),
        "strategy": str(data.get("strategy", "TRENDLINE")).upper(),
        "expires_at": (datetime.now(timezone.utc) + timedelta(minutes=SIGNAL_TTL_MINUTES)).isoformat(),
        "analysis": str(data.get("analysis", "Trend + RSI + MACD + zone alignment")),
        "timeframe": str(data.get("timeframe", "")), "price": data.get("price"), "ema_fast": data.get("ema_fast"),
        "ema_slow": data.get("ema_slow"), "rsi": data.get("rsi"), "macd": data.get("macd"),
        "macd_signal": data.get("macd_signal"), "atr": data.get("atr"),
        }
    except (TypeError, ValueError):
        return jsonify(error="numeric payload fields are invalid"), 400
    validation_error = validate_trade(signal)
    if validation_error:
        return jsonify(error=validation_error), 400
    if setting("trading_paused", "false") == "true":
        return jsonify(ok=True, sent=False, reason="Trading is paused")
    if news_blocked():
        return jsonify(ok=True, sent=False, reason="Trading is paused for high-impact news")
    accepted, final_confidence, review = consensus(signal)
    if not accepted:
        with db() as con:
            log_event(con, signal_id, "filtered", review)
        return jsonify(ok=True, sent=False, reason="Signal filtered: " + review)
    signal["confidence"], signal["analysis"] = final_confidence, review
    with db() as con:
        con.execute("INSERT INTO signals (id, created_at, symbol, side, order_type, entry, zone_low, zone_high, sl, tp1, tp2, tp3, risk_pct, confidence, pattern, timeframe, strategy, expires_at, analysis, status) VALUES (:id,:created_at,:symbol,:side,:order_type,:entry,:zone_low,:zone_high,:sl,:tp1,:tp2,:tp3,:risk_pct,:confidence,:pattern,:timeframe,:strategy,:expires_at,:analysis,'pending')", signal)
        log_event(con, signal_id, "created", signal["strategy"])
    owner = owner_chat_id()
    if not owner: return jsonify(error="Telegram owner missing: send /start to the bot first"), 503
    keyboard = {"inline_keyboard": [[
        {"text": "✅ Tasdiqlash", "callback_data": f"approve:{signal_id}"},
        {"text": "❌ Rad etish", "callback_data": f"reject:{signal_id}"}],
        [{"text": "📊 Batafsil tahlil", "callback_data": f"detail:{signal_id}"}]]}
    telegram("sendMessage", {"chat_id": owner, "text": fmt(signal), "parse_mode": "HTML", "reply_markup": keyboard})
    telegram_send_chart(owner, signal)
    return jsonify(ok=True, id=signal_id)

@app.post("/telegram/webhook")
def telegram_webhook():
    update = request.get_json(silent=True) or {}
    message = update.get("message") or {}
    chat_id = message.get("chat", {}).get("id")
    command = message.get("text", "").strip()
    if command.startswith("/start"):
        if chat_id and claim_owner(chat_id):
            telegram("sendMessage", {"chat_id": chat_id, "text": "Bot connected. Commands: /status, /pause, /resume, /risk 0.5, /newsblock 30, /newsresume"})
        elif chat_id:
            telegram("sendMessage", {"chat_id": chat_id, "text": "This bot is already linked to another owner."})
        return "ok"
    if command and require_owner(chat_id):
        if command == "/pause":
            set_setting("trading_paused", "true")
            telegram("sendMessage", {"chat_id": chat_id, "text": "Trading paused. New signals will be rejected."})
        elif command == "/resume":
            set_setting("trading_paused", "false")
            telegram("sendMessage", {"chat_id": chat_id, "text": "Trading resumed."})
        elif command.startswith("/risk"):
            parts = command.split(maxsplit=1)
            try:
                risk = float(parts[1])
                if not 0.01 <= risk <= 5:
                    raise ValueError
            except (IndexError, ValueError):
                telegram("sendMessage", {"chat_id": chat_id, "text": "Usage: /risk 0.5 (allowed: 0.01 to 5)"})
            else:
                set_setting("risk_pct", risk)
                telegram("sendMessage", {"chat_id": chat_id, "text": f"Default risk set to {risk:.2f}%."})
        elif command.startswith("/newsblock"):
            parts = command.split(maxsplit=1)
            try:
                minutes = int(parts[1])
                if not 1 <= minutes <= 480:
                    raise ValueError
            except (IndexError, ValueError):
                telegram("sendMessage", {"chat_id": chat_id, "text": "Usage: /newsblock 30 (1 to 480 minutes)"})
            else:
                until = (datetime.now(timezone.utc) + timedelta(minutes=minutes)).isoformat()
                set_setting("news_block_until", until)
                telegram("sendMessage", {"chat_id": chat_id, "text": f"News safety block enabled for {minutes} minutes."})
        elif command == "/newsresume":
            set_setting("news_block_until", "")
            telegram("sendMessage", {"chat_id": chat_id, "text": "News safety block cleared."})
        elif command == "/status":
            with db() as con:
                expire_signals(con)
                rows = con.execute("SELECT status, COUNT(*) AS count FROM signals GROUP BY status").fetchall()
            counts = ", ".join(f"{row['status']}: {row['count']}" for row in rows) or "no signals"
            paused = setting("trading_paused", "false") == "true"
            mode = "NEWS BLOCK" if news_blocked() else "PAUSED" if paused else "ACTIVE"
            telegram("sendMessage", {"chat_id": chat_id, "text": f"Trading: {mode}\n{counts}"})
        return "ok"
    query = update.get("callback_query")
    if not query or not require_owner(query.get("message", {}).get("chat", {}).get("id")):
        return "ok"
    action, signal_id = query.get("data", ":").split(":", 1)
    with db() as con:
        expire_signals(con)
        row = con.execute("SELECT * FROM signals WHERE id=?", (signal_id,)).fetchone()
        if not row:
            telegram("answerCallbackQuery", {"callback_query_id": query["id"], "text": "Signal topilmadi"})
            return "ok"
        signal = dict(row)
        status = "approved" if action == "approve" else "rejected" if action == "reject" else signal["status"]
        if action in ("approve", "reject") and signal["status"] == "pending":
            con.execute("UPDATE signals SET status=? WHERE id=?", (status, signal_id))
            log_event(con, signal_id, status, "telegram")
        msg = fmt(signal) if action == "detail" else ("✅ Tasdiqlandi. MT5 EA orderni tekshiradi." if action == "approve" else "❌ Signal rad etildi.")
    if action == "approve" and signal["status"] == "expired":
        msg = "Signal expired; it cannot be approved."
    elif action in ("approve", "reject") and signal["status"] != "pending":
        msg = "This signal was already processed."
    telegram("answerCallbackQuery", {"callback_query_id": query["id"], "text": "Qabul qilindi"})
    telegram("sendMessage", {"chat_id": owner_chat_id(), "text": msg, "parse_mode": "HTML"})
    if action in ("approve", "reject", "detail"):
        telegram_send_chart(owner_chat_id(), signal)
    return "ok"

@app.get("/mt5/next")
def mt5_next():
    if not APP_KEY or not secrets.compare_digest(request.headers.get("X-Api-Key", ""), APP_KEY):
        abort(401)
    with db() as con:
        expire_signals(con)
        row = con.execute("SELECT * FROM signals WHERE status='approved' ORDER BY created_at LIMIT 1").fetchone()
        if not row:
            return Response("NONE", mimetype="text/plain")
        s = dict(row)
    # Delimiter format keeps MQL parsing dependency-free.
    return Response("OPEN|{id}|{symbol}|{side}|{order_type}|{entry}|{sl}|{tp1}|{tp2}|{tp3}|{risk_pct}|{strategy}".format(**s), mimetype="text/plain")

@app.post("/mt5/ack/<signal_id>")
def mt5_ack(signal_id):
    if not APP_KEY or not secrets.compare_digest(request.headers.get("X-Api-Key", ""), APP_KEY):
        abort(401)
    with db() as con:
        result = con.execute("UPDATE signals SET status='sent_to_mt5' WHERE id=? AND status='approved'", (signal_id,))
        if result.rowcount:
            log_event(con, signal_id, "sent_to_mt5", "acknowledged by EA")
    return jsonify(ok=True)

@app.get("/health")
def health():
    return jsonify(ok=True, telegram_configured=bool(TG_TOKEN), owner_configured=bool(owner_chat_id()),
                   openai_configured=bool(OPENAI_KEY), gemini_configured=bool(GEMINI_KEY),
                   claude_configured=bool(CLAUDE_KEY), claude_enabled=CLAUDE_ENABLED)

@app.get("/dashboard")
def dashboard():
    if not APP_KEY or not secrets.compare_digest(request.headers.get("X-Api-Key", ""), APP_KEY):
        abort(401)
    with db() as con:
        expire_signals(con)
        counts = {row["status"]: row["count"] for row in con.execute(
            "SELECT status, COUNT(*) AS count FROM signals GROUP BY status")}
        recent = [dict(row) for row in con.execute(
            "SELECT id, created_at, symbol, side, strategy, confidence, expires_at, status "
            "FROM signals ORDER BY created_at DESC LIMIT 20")]
        events = [dict(row) for row in con.execute(
            "SELECT signal_id, created_at, event, detail FROM signal_events ORDER BY id DESC LIMIT 30")]
    return jsonify(trading_paused=setting("trading_paused", "false") == "true",
                   news_blocked=news_blocked(), news_block_until=setting("news_block_until", ""),
                   default_risk_pct=float(setting("risk_pct", os.getenv("DEFAULT_RISK_PERCENT", "0.5"))),
                   status_counts=counts, recent_signals=recent, recent_events=events)

@app.get("/selftest")
def selftest():
    result = send_self_test_message()
    return jsonify(result)

@app.get("/mt5/test")
def mt5_test():
    if not APP_KEY or not secrets.compare_digest(request.headers.get("X-Api-Key", ""), APP_KEY):
        abort(401)
    return Response("OK|monitor|alive|" + datetime.now(timezone.utc).isoformat(), mimetype="text/plain")

@app.get("/")
def index():
    return jsonify(service="AI Zone Trader", health="/health", status="running")

@app.get("/chart")
def chart():
    sample = {
        "symbol": "EURUSD",
        "side": "BUY",
        "entry": 1.0925,
        "zone_low": 1.0890,
        "zone_high": 1.0940,
        "sl": 1.0850,
        "tp1": 1.0995,
        "tp2": 1.1045,
        "tp3": 1.1090,
        "confidence": 82,
        "timeframe": "H1",
    }
    return Response(generate_trade_visualization(sample), mimetype="image/png")

if __name__ == "__main__":
    init_db()
    configure_telegram_webhook()
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
else:
    # Vercel imports the Flask app instead of running this file as __main__.
    init_db()
    if os.getenv("AUTO_CONFIGURE_TELEGRAM_WEBHOOK", "false").lower() == "true":
        configure_telegram_webhook()
