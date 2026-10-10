# AI Zone Trader (MT5)

A MetaTrader 5 Expert Advisor. It finds rule-based setups (EMA/RSI/ATR, order blocks,
BOS/CHOCH, trendlines). Claude and Gemini review each setup. Signals and ✅/❌ approval
buttons go to Telegram. Each trade has a stop-loss and a 3-part take profit: 50% at
1.5R, 25% at 2.25R and 25% at 3R, with the stop moved to entry and then to TP1.
Each AI keeps a journal of its past calls and writes itself lessons after mistakes.

Full guide (Uzbek): [mt5/README_UZ.md](mt5/README_UZ.md)

| Path | Purpose |
|---|---|
| `mt5/` | Everything that goes into MT5 and `Install-MT5.ps1`, which installs it |
| `mt5/AZT_Config.ini.example` | Format of the private `MQL5/Files/AZT_Config.ini` (all keys live there) |
| `tests/` | MQL5 test scripts, run in an isolated portable terminal |
| `mt5/VALIDATION.md` | What was compiled and tested |

No AI review guarantees profitable trades. Test on a demo account first.
