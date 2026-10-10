// Deterministic tests of production structure and OHLC history settlement.
// This script never initializes the EA, connects Telegram or places orders.
#define OnInit EA_OnInit
#define OnDeinit EA_OnDeinit
#define OnTick EA_OnTick
#define OnTimer EA_OnTimer
#include "../mt5/AI_Zone_Trader_EA.mq5"
#undef OnInit
#undef OnDeinit
#undef OnTick
#undef OnTimer

int StructurePassed=0, StructureFailed=0;
void StructureCheck(bool ok,string name) {
   if(ok) { StructurePassed++; Print("PASS: ",name); }
   else { StructureFailed++; Print("FAIL: ",name); }
}
void StructureFixture() {
   ArrayResize(Rates,160); ArrayResize(ATR,160);
   ArraySetAsSeries(Rates,true); ArraySetAsSeries(ATR,true);
   for(int i=0;i<160;i++) {
      ZeroMemory(Rates[i]);
      Rates[i].time=D'2026.09.01 12:00'-i*60;
      Rates[i].open=100; Rates[i].close=100;
      Rates[i].high=101; Rates[i].low=99; ATR[i]=1;
   }
   InvalidateStructureCache(); ResetStructure();
}
void BlockFixture() {
   StructureFixture();
   Rates[20].high=110;
   Rates[11].open=101; Rates[11].close=100; Rates[11].high=102;
   Rates[10].open=100; Rates[10].close=112; Rates[10].high=113; Rates[10].low=100;
   Rates[9].open=113; Rates[9].close=114; Rates[9].high=115; Rates[9].low=112;
   Rates[8].open=113; Rates[8].close=110; Rates[8].high=114; Rates[8].low=105;
   Rates[7].open=103; Rates[7].close=105; Rates[7].high=111; Rates[7].low=101;
   Rates[6].open=105; Rates[6].close=106; Rates[6].high=107; Rates[6].low=104;
   Rates[5].open=103; Rates[5].close=105; Rates[5].high=106; Rates[5].low=101;
}
void OnStart() {
   int side; string setup,reason; double anchor;
   BlockFixture();
   StructureCheck(!ConfirmedPivot(20,18,true),"pivot cannot confirm before right-hand candles close");
   StructureCheck(ConfirmedPivot(20,17,true),"pivot confirms after configured right-hand candles");
   StructureCheck(!EvaluateStructureSignal(0,side,setup,anchor,reason),"structure rejects forming candle");
   StructureCheck(EvaluateStructureSignal(10,side,setup,anchor,reason) && side==1 &&
      StringFind(setup,"BOS")>=0,"confirmed impulsive swing break emits BUY");
   string pastSetup=setup; double pastAnchor=anchor;
   StructureCheck(EvaluateStructureSignal(7,side,setup,anchor,reason) && side==1 &&
      setup=="Fresh order-block rejection" && anchor==99,"first fresh OB rejection emits BUY with zone anchor");
   StructureCheck(!EvaluateStructureSignal(5,side,setup,anchor,reason) ||
      setup!="Fresh order-block rejection","mitigated OB cannot emit another fresh-block signal");
   for(int i=0;i<10;i++) { Rates[i].open=200; Rates[i].close=201; Rates[i].high=202; Rates[i].low=199; ATR[i]=20; }
   InvalidateStructureCache();
   StructureCheck(EvaluateStructureSignal(10,side,setup,anchor,reason) && setup==pastSetup && anchor==pastAnchor,
      "future candles cannot change historical structure signal after full rebuild");
   BlockFixture(); Rates[8].close=98; Rates[8].low=97;
   InvalidateStructureCache();
   StructureCheck(!EvaluateStructureSignal(7,side,setup,anchor,reason) ||
      setup!="Fresh order-block rejection","close beyond far edge invalidates block before later retest");
   BlockFixture(); Rates[10].open=111.8;
   InvalidateStructureCache();
   StructureCheck(!EvaluateStructureSignal(10,side,setup,anchor,reason) ||
      StringFind(setup,"BOS")<0,"weak break does not qualify as impulse setup");

   StructureFixture();
   PreviousLow.time=Rates[20].time; PreviousLow.price=96; PreviousLow.shift=20;
   LowPivot.time=Rates[10].time; LowPivot.price=98; LowPivot.shift=10;
   Rates[5].open=100; Rates[5].close=101; Rates[5].low=99; Rates[5].high=102;
   AZTStructureSignal candidate;
   FindStructureSetup(5,candidate);
   StructureCheck(candidate.side==1 && candidate.setup=="Rising trendline rejection",
      "confirmed rising support with closed-candle rejection emits setup");
   Rates[6].close=98;
   FindStructureSetup(5,candidate);
   StructureCheck(candidate.side==0,"intervening close through line invalidates trendline setup");

   StructureFixture();
   LocalSignal signal; ZeroMemory(signal);
   signal.side=1; signal.sl=95; signal.entry=100; signal.atr=1;
   double resultR; int exitShift;
   Rates[4].high=116; Rates[4].low=94;
   AZTHistoryOutcome outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_STOP && MathAbs(resultR+1)<0.000001,
      "same OHLC bar touching SL and TP charges stop first");
   StructureFixture(); Rates[3].open=92; Rates[3].high=94; Rates[3].low=91; Rates[3].close=93;
   outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_STOP && resultR<-1.0 && exitShift==3,
      "adverse stop gap can lose more than one R");
   StructureFixture(); Rates[4].open=102; Rates[4].high=124; Rates[4].low=101; Rates[4].close=120;
   outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_TARGET && MathAbs(resultR-PlanFullR())<0.000001,
      "history enters next bar open and recomputes all 3 targets from actual risk");
   StructureCheck(MathAbs(PlanFullR()-2.0625)<0.000001,"default plan: 50% @1.5R + 25% @2.25R + 25% @3R = 2.0625R");
   StructureFixture(); Rates[4].high=108; Rates[3].low=99;
   outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_STOP && MathAbs(resultR-0.75)<0.000001 && exitShift==3,
      "TP1 closes half, then remaining half stops at entry (+0.75R)");
   StructureFixture(); Rates[4].high=112; Rates[3].open=110; Rates[3].high=111; Rates[3].low=99;
   outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_STOP && MathAbs(resultR-1.6875)<0.000001,
      "TP1+TP2 taken, last quarter stops at TP1 (+1.6875R)");
   StructureFixture(); Rates[4].high=108; Rates[4].low=94;
   outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_STOP && MathAbs(resultR+1)<0.000001,
      "bar touching SL and TP1 together is counted as a full loss");

   if(MathAbs(VolumeMin()-0.01)<1e-9 && MathAbs(VolumeStep()-0.01)<1e-9) {
      StructureCheck(MathAbs(PartVolume(0.04,50,0.04)-0.02)<1e-9 && MathAbs(PartVolume(0.04,25,0.02)-0.01)<1e-9,
         "0.04 lot splits 0.02 / 0.01 / 0.01");
      StructureCheck(PartVolume(0.01,50,0.01)==0,"minimum lot is never split");
      StructureCheck(PartVolume(0.03,25,0.02)==0 && MathAbs(PartVolume(0.03,50,0.03)-0.01)<1e-9,
         "0.03 lot: 0.01 at TP1, rest runs to TP3");
   } else Print("SKIP: lot split checks need EURUSD with 0.01 lot step");

   // Journal: scoring, memory text and CSV round trip.
   ArrayResize(Journal,0);
   AZTAIVerdict verdicts[AZT_AI_COUNT];
   ZeroMemory(verdicts[0]); ZeroMemory(verdicts[1]);
   verdicts[0].ok=true; verdicts[0].decision=1; verdicts[0].confidence=80; verdicts[0].summary="Trend; mos";
   verdicts[1].ok=true; verdicts[1].decision=-1; verdicts[1].confidence=70; verdicts[1].summary="Qarshilik yaqin";
   signal.time=D'2026.09.01 10:00';
   JournalAdd("J1",signal,"RSI 55, H4 UP",verdicts,"AUTO");
   signal.time=D'2026.09.01 11:00';
   JournalAdd("J2",signal,"RSI 68, H4 DOWN",verdicts,"WAITING");
   Journal[0].outcome=1; Journal[0].stage=1; Journal[0].resultR=0.75;
   Journal[1].outcome=-1; Journal[1].resultR=-1;
   StructureCheck(JournalCorrect(Journal[0],0)==1 && JournalCorrect(Journal[0],1)==-1,"APPROVE on a TP1 winner is right, REJECT is wrong");
   StructureCheck(JournalCorrect(Journal[1],0)==-1 && JournalCorrect(Journal[1],1)==1,"APPROVE on a stopped trade is wrong, REJECT is right");
   int samples; double precision=JournalApprovePrecision(0,samples);
   StructureCheck(samples==2 && MathAbs(precision-50)<1e-9,"approve precision counted per provider");
   string memory=JournalMemory(0);
   StructureCheck(StringFind(memory,"WRONG")>0 && StringFind(memory,"RIGHT")>0 && StringFind(memory,"1/2")>0,
      "each AI sees its own right/wrong record");
   JournalSetAction("J2","USER_REJECT");
   JournalSave(); ArrayResize(Journal,0); JournalLoad();
   StructureCheck(ArraySize(Journal)==2 && Journal[1].action=="USER_REJECT" && Journal[0].why[0]=="Trend, mos" &&
      Journal[1].outcome==-1 && Journal[0].dec[1]==-1,"journal survives save/load (separator in text sanitized)");
   FileDelete(JournalFile());
   StructureFixture(); Rates[4].open=94;
   outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_INVALID_ENTRY,"entry already beyond original SL is skipped");
   StructureFixture(); Rates[0].low=1; Rates[0].high=1000;
   outcome=AnalyzeHistoricalSignal(signal,1,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_PENDING,"latest signal is pending without reading forming bar");
   outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_PENDING,"unresolved recent samples are counted pending");
   outcome=AnalyzeHistoricalSignal(signal,130,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_TIME && MathAbs(resultR)<0.000001 &&
      exitShift==130-HistoryMaxHoldingBars,"flat mature sample is time-exited instead of discarded");
   StructureFixture(); signal.side=-1; signal.sl=105;
   Rates[4].high=106; Rates[4].low=84;
   outcome=AnalyzeHistoricalSignal(signal,5,resultR,exitShift);
   StructureCheck(outcome==AZT_HISTORY_STOP && MathAbs(resultR+1)<0.000001,
      "SELL history applies the same conservative touch order");

   string result="AZT_STRUCTURE_HISTORY_RESULT passed="+(string)StructurePassed+" failed="+(string)StructureFailed;
   Print(result);
   int file=FileOpen("azt_structure_history_result.txt",FILE_WRITE|FILE_TXT);
   if(file!=INVALID_HANDLE) { FileWrite(file,result); FileClose(file); }
}
