// Runs the production signal evaluator on controlled candles. No trading calls.
#define OnInit EA_OnInit
#define OnDeinit EA_OnDeinit
#define OnTick EA_OnTick
#define OnTimer EA_OnTimer
#include "../mt5/AI_Zone_Trader_EA.mq5"
#undef OnInit
#undef OnDeinit
#undef OnTick
#undef OnTimer

int Passed=0, Failed=0;
void Check(bool ok, string name) {
   if(ok) { Passed++; Print("PASS: ",name); }
   else { Failed++; Print("FAIL: ",name); }
}
void Fixture(bool buy=true) {
   InvalidateStructureCache();
   ArrayResize(Rates,32); ArrayResize(Fast,32); ArrayResize(Slow,32);
   ArrayResize(RSI,32); ArrayResize(ATR,32);
   ArrayResize(MACDMain,32); ArrayResize(MACDSignal,32); ArrayResize(TrendMA,32);
   ArraySetAsSeries(Rates,true); ArraySetAsSeries(Fast,true); ArraySetAsSeries(Slow,true);
   ArraySetAsSeries(RSI,true); ArraySetAsSeries(ATR,true);
   ArraySetAsSeries(MACDMain,true); ArraySetAsSeries(MACDSignal,true); ArraySetAsSeries(TrendMA,true);
   for(int i=0;i<32;i++) {
      Rates[i].time=D'2026.09.01 12:00'-i*60;
      Rates[i].open=100; Rates[i].close=buy ? 102 : 98;
      Rates[i].high=103; Rates[i].low=97;
      Fast[i]=100; Slow[i]=buy ? 99 : 101;
      RSI[i]=buy ? 55 : 45; ATR[i]=2;
      // MACD rising above its signal line and price above MA200 (mirrored for SELL): score 2.
      MACDMain[i]=buy ? 1.0-i*0.01 : -1.0+i*0.01; MACDSignal[i]=0;
      TrendMA[i]=buy ? 90 : 110;
   }
}
void OnStart() {
   Check(AZTPositionSlotAvailable(1,0,3,true,true),"hedging allows second signal on same symbol");
   Check(AZTPositionSlotAvailable(2,0,3,true,true),"hedging allows third position");
   Check(!AZTPositionSlotAvailable(3,0,3,true,true),"fourth position blocked at cap");
   Check(!AZTPositionSlotAvailable(2,1,3,true,false),"pending order occupies a slot");
   Check(!AZTPositionSlotAvailable(1,0,3,false,true),"netting cannot merge a new signal into existing symbol");
   Check(AZTPositionSlotAvailable(1,0,3,false,false),"netting allows another symbol within cap");
   LocalSignal signal; string reason;
   Fixture();
   Check(TradeMode!=AZT_SIGNALS_ONLY && TP3_R>=3.0,"default mode asks AI/approval and targets 1:3");
   Check(EvaluateSignal(1,signal,reason) && signal.side==1 && signal.setup=="EMA pullback","BUY pullback");
   Check(signal.sl<signal.entry && signal.entry<signal.tp1 && signal.tp1<=signal.tp2 && signal.tp2<=signal.tp3,"BUY SL/TP direction");
   Check(signal.entry-signal.sl>=StopATR*signal.atr,"ATR minimum stop distance");
   double savedEntry=signal.entry, savedSL=signal.sl;
   Rates[0].close=10000; Rates[0].low=0; Fast[0]=999; Slow[0]=1; RSI[0]=99; ATR[0]=500;
   Check(EvaluateSignal(1,signal,reason) && signal.entry==savedEntry && signal.sl==savedSL,"forming candle cannot alter closed signal");
   Check(!EvaluateSignal(0,signal,reason),"forming candle cannot be evaluated as a signal");
   RSI[1]=70;
   Check(!EvaluateSignal(1,signal,reason),"overbought BUY rejected");
   RSI[1]=50;
   Check(!EvaluateSignal(1,signal,reason),"neutral BUY RSI rejected");
   Fixture(false);
   Check(EvaluateSignal(1,signal,reason) && signal.side==-1,"SELL pullback");
   Check(signal.sl>signal.entry && signal.entry>signal.tp1 && signal.tp1>=signal.tp2 && signal.tp2>=signal.tp3,"SELL SL/TP direction");
   RSI[1]=30;
   Check(!EvaluateSignal(1,signal,reason),"oversold SELL rejected");
   Fixture(); Fast[1]=Slow[1];
   Check(!EvaluateSignal(1,signal,reason),"flat EMA trend rejected");
   Fixture(); ATR[1]=0;
   Check(!EvaluateSignal(1,signal,reason),"zero ATR rejected");
   Fixture(); Rates[1].low=101; Fast[2]=98;
   Check(EvaluateSignal(1,signal,reason) && signal.setup=="EMA cross","BUY crossover without pullback");
   Fixture(false); Rates[1].high=99; Fast[2]=102;
   Check(EvaluateSignal(1,signal,reason) && signal.setup=="EMA cross","SELL crossover without pullback");
   Fixture(); Rates[1].low=101;
   Check(!EvaluateSignal(1,signal,reason),"trend alone does not emit signals");
   Check(!EvaluateSignal(30,signal,reason),"insufficient lookback rejected");

   // Confluence: classic indicators must agree.
   Fixture();
   Check(EvaluateSignal(1,signal,reason) && signal.score==2 && StringFind(signal.factors,"MACD bullish")>=0 &&
      StringFind(signal.factors,"MA200 ustida")>=0,"MACD and MA200 agreement scored and listed");
   Fixture(); MACDMain[1]=-0.5; MACDMain[2]=-0.4;
   Check(!EvaluateSignal(1,signal,reason) && StringFind(reason,"confluence")>=0,"bearish MACD drops BUY below MinConfluence");
   Fixture(); TrendMA[1]=110;
   Check(!EvaluateSignal(1,signal,reason),"BUY under MA200 rejected by confluence");
   Fixture();
   Rates[5].open=98; Rates[5].close=98.5; Rates[5].high=99; Rates[5].low=97;     // candle j+1
   Rates[3].open=101.5; Rates[3].close=102; Rates[3].high=103; Rates[3].low=101; // candle j-1: gap 99-101
   Rates[2].low=100;                                                               // gap not filled
   Check(EvaluateSignal(1,signal,reason) && signal.score==3 && StringFind(signal.factors,"FVG")>=0,
      "reaction from unfilled bullish FVG adds a confirmation");
   string result="AZT_TEST_RESULT passed="+(string)Passed+" failed="+(string)Failed;
   Print(result);
   int file=FileOpen("azt_test_result.txt",FILE_WRITE|FILE_TXT);
   if(file!=INVALID_HANDLE) { FileWrite(file,result); FileClose(file); }
}
