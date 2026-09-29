# Validation — standalone EA 1.00

- Compiled `AI_Zone_Trader_EA.mq5` with the installed MetaEditor compiler:
  **0 errors, 0 warnings**, X64 Regular. Output: `AI_Zone_Trader_EA.ex5`.
- Compiled `tests/test_mt5_signals.mq5`: **0 errors, 0 warnings**.
- Executed that test script in an isolated portable MT5 instance with automatic
  trading disabled, no copied account credentials and controlled candle fixtures:
  **17 passed, 0 failed**.
- The script includes and executes the production evaluator, covering BUY/SELL
  pullbacks and crossovers, RSI boundaries, flat trend, unavailable ATR/history,
  SL/TP ordering, ATR stop distance, and independence from the forming candle.

No broker-account orders or historical profitability backtest were run. These
checks verify compilation and the signal rules, not live execution, expected
signal frequency, profitability, popup delivery or phone notification delivery.

To repeat the signal tests, compile `tests/test_mt5_signals.mq5` in place (it
includes `../mt5/AI_Zone_Trader_EA.mq5`), copy its EX5 into an isolated terminal's
`MQL5/Scripts`, and run it on a chart with the default inputs. Results appear in
Experts and `MQL5/Files/azt_test_result.txt`. The test does not call the order code.
