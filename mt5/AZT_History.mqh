// Closed-bar research replay, using the SAME EvaluateSignal as live alerts and
// the SAME 3-part exit plan as live position management.
// Independent setups may overlap: this is not an account or tick backtest.
// Include after LocalSignal, EvaluateSignal, RequiredBars and DrawSignal.
#ifndef AZT_HISTORY_MQH
#define AZT_HISTORY_MQH

enum AZTHistoryOutcome {
   AZT_HISTORY_PENDING=0,
   AZT_HISTORY_TARGET=1,       // TP3 reached (all parts closed in profit)
   AZT_HISTORY_STOP=-1,        // Remaining part stopped (at SL, entry or TP1)
   AZT_HISTORY_TIME=2,
   AZT_HISTORY_INVALID_ENTRY=3
};

string HistoryStatus="History analysis pending";
int HistoryTrades=0, HistoryWins=0, HistoryLosses=0;
int HistoryTargets=0, HistoryStops=0, HistoryTimedExits=0, HistoryTP1=0;
int HistoryPending=0, HistorySkipped=0;
double HistoryTotalR=0, HistoryExpectancyR=0;

double PlanFraction(int part) {
   if(part==0) return TP1ClosePercent/100.0;
   if(part==1) return TP2ClosePercent/100.0;
   return 1.0-(TP1ClosePercent+TP2ClosePercent)/100.0;
}

double PlanTargetR(int part) { return part==0 ? TP1_R : part==1 ? TP2_R : TP3_R; }

// R earned when every part reaches its target.
double PlanFullR() {
   double total=0;
   for(int part=0;part<3;part++) total+=PlanFraction(part)*PlanTargetR(part);
   return total;
}

// Walks closed bars from `fromShift` (entry bar) towards shift 1, never bar 0.
// stage = number of targets reached (0..3). OHLC cannot reveal touch order, so
// the current stop is always checked before targets on the same bar.
AZTHistoryOutcome SimulatePlan(int side,double entry,double sl,int fromShift,int maxBars,
                               double &resultR,int &stage,int &exitShift) {
   resultR=0; stage=0; exitShift=0;
   double risk=side*(entry-sl);
   if((side!=1 && side!=-1) || !MathIsValidNumber(entry) || entry<=0 || risk<=0 || !MathIsValidNumber(risk))
      return AZT_HISTORY_INVALID_ENTRY;
   if(fromShift<1 || fromShift>=ArraySize(Rates)) return AZT_HISTORY_PENDING;
   double stop=sl, realized=0, remaining=1.0;
   int last=MathMax(1,fromShift-maxBars+1);
   for(int i=fromShift;i>=last;i--) {
      double exitPrice=0;
      AZTHistoryOutcome outcome=AZT_HISTORY_PENDING;
      bool stopHit=side==1 ? Rates[i].low<=stop : Rates[i].high>=stop;
      if(side*(Rates[i].open-stop)<=0) { exitPrice=Rates[i].open; outcome=AZT_HISTORY_STOP; } // gap: can lose >1R
      else if(stopHit) { exitPrice=stop; outcome=AZT_HISTORY_STOP; }
      else {
         while(stage<3) {
            double target=entry+side*risk*PlanTargetR(stage);
            bool hit=side==1 ? Rates[i].high>=target : Rates[i].low<=target;
            if(!hit) break;
            // No favorable gap windfall: a resting target fills at its level.
            realized+=PlanFraction(stage)*PlanTargetR(stage);
            remaining-=PlanFraction(stage);
            stage++;
            if(MoveSLAfterTP) stop=stage==1 ? entry : entry+side*risk*PlanTargetR(stage-2);
         }
         if(stage>=3) { resultR=realized; exitShift=i; return AZT_HISTORY_TARGET; }
         if(fromShift-i+1>=maxBars) { exitPrice=Rates[i].close; outcome=AZT_HISTORY_TIME; }
      }
      if(outcome!=AZT_HISTORY_PENDING) {
         resultR=realized+remaining*side*(exitPrice-entry)/risk;
         exitShift=i;
         return outcome;
      }
   }
   resultR=realized;
   return AZT_HISTORY_PENDING;
}

AZTHistoryOutcome AnalyzeHistoricalSignal(const LocalSignal &signal,int signalShift,
                                         double &resultR,int &exitShift) {
   resultR=0; exitShift=0;
   // shift 1 has no CLOSED next bar yet. Never read bar 0's open/high/low.
   if(signalShift<2 || signalShift>=ArraySize(Rates)) return AZT_HISTORY_PENDING;
   int entryShift=signalShift-1, stage=0;
   double entry=Rates[entryShift].open;
   // Original SL kept; targets recalculated from the actual next-open risk.
   AZTHistoryOutcome outcome=SimulatePlan(signal.side,entry,signal.sl,entryShift,HistoryMaxHoldingBars,resultR,stage,exitShift);
   if(outcome==AZT_HISTORY_PENDING || outcome==AZT_HISTORY_INVALID_ENTRY) { resultR=0; return outcome; }
   if(stage>0) HistoryTP1++;
   resultR-=HistoryRoundTripCostPoints*_Point/(signal.side*(entry-signal.sl));
   return outcome;
}

void RunHistoricalAnalysis(bool draw=true) {
   HistoryTrades=0; HistoryWins=0; HistoryLosses=0;
   HistoryTargets=0; HistoryStops=0; HistoryTimedExits=0; HistoryTP1=0;
   HistoryPending=0; HistorySkipped=0; HistoryTotalR=0; HistoryExpectancyR=0;
   HistoricalSignals=0;
   int oldest=MathMax(0,MathMin(HistoryBars,ArraySize(Rates)-RequiredBars()));
   int previousSignalShift=-1;
   if(draw) LastSignalBar=0;
   for(int shift=oldest;shift>=1;shift--) {
      LocalSignal signal; string reason;
      if(!EvaluateSignal(shift,signal,reason)) continue;
      if(previousSignalShift>=shift && previousSignalShift-shift<CooldownBars) continue;
      previousSignalShift=shift;
      HistoricalSignals++;
      if(draw) { DrawSignal(signal,true); LastSignalBar=signal.time; }
      double resultR; int exitShift;
      AZTHistoryOutcome outcome=AnalyzeHistoricalSignal(signal,shift,resultR,exitShift);
      if(outcome==AZT_HISTORY_PENDING) { HistoryPending++; continue; }
      if(outcome==AZT_HISTORY_INVALID_ENTRY) { HistorySkipped++; continue; }
      HistoryTrades++; HistoryTotalR+=resultR;
      if(resultR>0) HistoryWins++;
      else if(resultR<0) HistoryLosses++;
      if(outcome==AZT_HISTORY_TARGET) HistoryTargets++;
      else if(outcome==AZT_HISTORY_STOP) HistoryStops++;
      else if(outcome==AZT_HISTORY_TIME) HistoryTimedExits++;
   }
   double winRate=HistoryTrades>0 ? 100.0*HistoryWins/HistoryTrades : 0;
   if(HistoryTrades>0) HistoryExpectancyR=HistoryTotalR/HistoryTrades;
   string estimate=HistoryTrades>0 ? DoubleToString(HistoryExpectancyR,2)+" R | win="+DoubleToString(winRate,1)+"%"
                                 : "n/a (no completed samples)";
   string costs=HistoryRoundTripCostPoints>0 ? "configured cost="+DoubleToString(HistoryRoundTripCostPoints,1)+" pts"
                                           : "GROSS: costs excluded";
   HistoryStatus=(string)oldest+" bars | setups="+(string)HistoricalSignals+
      " scored="+(string)HistoryTrades+" TP1+="+(string)HistoryTP1+" TP3="+(string)HistoryTargets+
      " stopped="+(string)HistoryStops+" time-exit="+(string)HistoryTimedExits+" pending="+(string)HistoryPending+
      "\nResearch expectancy (3-part plan): "+estimate+" | "+costs+
      "\nOverlapping samples; next open; stop first; time exit "+(string)HistoryMaxHoldingBars+
      " bars. Not an account backtest.";
   if(draw) Print("AZT historical analysis: ",HistoryStatus,
      " Commission, variable spread, slippage, swap and account risk limits are not modeled unless approximated by configured point costs.");
}
#endif
