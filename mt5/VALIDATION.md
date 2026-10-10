# Validation — EA 4.00

- `AI_Zone_Trader_EA.mq5` compiled with MetaEditor: **0 errors, 0 warnings** (X64 Regular).
- Test scripts were compiled (0 errors, 0 warnings) and run in an isolated portable
  MT5 instance with Algo Trading off and no account login:
  - `test_mt5_signals`: **17 passed, 0 failed**. Covers signal rules and defaults
    (AI hybrid mode, 1:3 main target).
  - `test_mt5_structure_history`: **31 passed, 0 failed**. Covers structure and order
    blocks, plus the 3-part exit plan:
    - full plan = 2.0625R
    - TP1 then breakeven = +0.75R
    - TP1 and TP2, then stop at TP1 = +1.6875R
    - stop-first on ambiguous bars
    - lot splitting (0.04 → 0.02/0.01/0.01; 0.01 never split)
    - journal scoring, per-AI precision and memory text
    - CSV save/load
  - `test_mt5_telegram`: **40 passed, 0 failed**. WebRequest is faked, so nothing reaches
    Telegram, Anthropic or Google. Covers:
    - the send queue
    - JSON decoding
    - AI verdict parsing
    - the lessons file (newest 30)
    - approval buttons and `getUpdates` callbacks
    - rejection of the wrong chat and of non-admin users
- `Install-MT5.ps1` was run against the local MT5 terminal. It installed the EA into
  `MQL5/Experts/AI_Zone_Trader/` and created `MQL5/Files/AZT_Config.ini` with the
  Telegram, Claude and Gemini values filled in.

Not verified: live Claude/Gemini answers (use the chart's **AI TEST** button), live
Telegram button presses, broker execution of partial closes and stop moves, and
profitability. Check these on a demo account.

To run a test: compile it in place, copy the EX5 to the portable terminal's
`MQL5/Scripts`, then start `terminal64.exe /portable /config:<ini>` with the script
named in `[StartUp]`. Results are written to `MQL5/Files/azt_*_result.txt`.
