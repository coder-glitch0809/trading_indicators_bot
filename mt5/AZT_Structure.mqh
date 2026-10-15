// Causal structure engine: series index 0 is NEVER used to decide a signal.
// An OB is an opposite candle before an impulsive confirmed swing break,
// a price-action heuristic, not proof of institutional orders or machine learning.
#ifndef AZT_STRUCTURE_MQH
#define AZT_STRUCTURE_MQH
struct AZTPivot {
   datetime time;
   double price;
   int shift;
   bool broken;
};
struct AZTBlock {
   int side;
   datetime origin, confirmed;
   double top, bottom;
   int bornShift;
   bool touched;
};
AZTPivot HighPivot, PreviousHigh, LowPivot, PreviousLow;
AZTBlock Blocks[];
int StructureBreakCount=0;
string StructureStatus="Waiting for confirmed pivots";
int StructureBias=0;

struct AZTStructureSignal {
   int side;
   string setup;
   double stopAnchor;
   double zoneTop, zoneBottom; // Kirish zonasi (OB, buzilgan daraja yoki trendline atrofi)
};
AZTStructureSignal StructureSignals[];
bool StructureCacheReady=false;
datetime StructureCacheTime=0;
int StructureCacheSize=0;

void InvalidateStructureCache() { StructureCacheReady=false; }

bool StructureATRValid(int shift) {
   return shift>=1 && shift<ArraySize(ATR) && MathIsValidNumber(ATR[shift]) &&
      ATR[shift]>0 && ATR[shift]!=EMPTY_VALUE;
}

void ExpireStructurePivots(int shift) {
   // Bound context to the same horizon during historical and live evaluations.
   if(HighPivot.time>0 && HighPivot.shift-shift>StructureLookback) ZeroMemory(HighPivot);
   if(PreviousHigh.time>0 && PreviousHigh.shift-shift>StructureLookback) ZeroMemory(PreviousHigh);
   if(LowPivot.time>0 && LowPivot.shift-shift>StructureLookback) ZeroMemory(LowPivot);
   if(PreviousLow.time>0 && PreviousLow.shift-shift>StructureLookback) ZeroMemory(PreviousLow);
}

bool ConfirmedPivot(int center, int confirmingShift, bool high) {
   if(confirmingShift<1 || center-PivotBars<confirmingShift || center+PivotBars>=ArraySize(Rates)) return false;
   double value=high ? Rates[center].high : Rates[center].low;
   for(int j=1;j<=PivotBars;j++) {
      // Strict extrema: equal highs/lows do not count as pivots.
      if(high && (Rates[center-j].high>=value || Rates[center+j].high>=value)) return false;
      if(!high && (Rates[center-j].low<=value || Rates[center+j].low<=value)) return false;
   }
   return true;
}

void RemoveBlock(int index) {
   int count=ArraySize(Blocks);
   for(int i=index;i<count-1;i++) Blocks[i]=Blocks[i+1];
   ArrayResize(Blocks,count-1);
}

void UpdateBlocks(int shift) {
   for(int i=ArraySize(Blocks)-1;i>=0;i--) {
      if(Blocks[i].bornShift<=shift) continue; // No same-candle mitigation.
      bool broken=(Blocks[i].side==1 ? Rates[shift].close<Blocks[i].bottom : Rates[shift].close>Blocks[i].top);
      if(broken || Blocks[i].bornShift-shift>MathMin(OBMaxAgeBars,StructureLookback)) { RemoveBlock(i); continue; }
      if(Rates[shift].low<=Blocks[i].top && Rates[shift].high>=Blocks[i].bottom) Blocks[i].touched=true;
   }
}

bool AddBlock(int shift, int side, int pivotShift) {
   if(!StructureATRValid(shift)) return false;
   double body=side*(Rates[shift].close-Rates[shift].open);
   if(body<ATR[shift]*OBImpulseATR) return false;
   int oldest=MathMin(pivotShift,MathMin(shift+OBSearchBars,ArraySize(Rates)-1));
   for(int j=shift+1;j<=oldest;j++) {
      bool opposite=side==1 ? Rates[j].close<Rates[j].open : Rates[j].close>Rates[j].open;
      if(!opposite) continue;
      if(Rates[j].high<=Rates[j].low) return false;
      // The nearest opposite candle defines the complete wick-to-wick zone.
      if((side==1 && Rates[shift].close<=Rates[j].high) ||
         (side==-1 && Rates[shift].close>=Rates[j].low)) return false;
      for(int k=0;k<ArraySize(Blocks);k++)
         if(Blocks[k].origin==Rates[j].time && Blocks[k].side==side) return false;
      int count=ArraySize(Blocks);
      if(count>=MaxOrderBlocks) { RemoveBlock(0); count--; }
      ArrayResize(Blocks,count+1);
      Blocks[count].side=side; Blocks[count].origin=Rates[j].time;
      Blocks[count].confirmed=Rates[shift].time;
      Blocks[count].top=Rates[j].high; Blocks[count].bottom=Rates[j].low;
      Blocks[count].bornShift=shift; Blocks[count].touched=false;
      return true;
   }
   return false;
}

void StructureText(string name, datetime time, double price, string label, color colour) {
   ObjectCreate(0,name,OBJ_TEXT,0,time,price);
   ObjectSetString(0,name,OBJPROP_TEXT,label);
   ObjectSetInteger(0,name,OBJPROP_COLOR,colour);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
}

void ProcessStructureBar(int shift, bool draw=true) {
   ExpireStructurePivots(shift);
   UpdateBlocks(shift);
   int center=shift+PivotBars;
   if(ConfirmedPivot(center,shift,true)) {
      PreviousHigh=HighPivot;
      HighPivot.time=Rates[center].time; HighPivot.price=Rates[center].high;
      HighPivot.shift=center; HighPivot.broken=false;
   }
   if(ConfirmedPivot(center,shift,false)) {
      PreviousLow=LowPivot;
      LowPivot.time=Rates[center].time; LowPivot.price=Rates[center].low;
      LowPivot.shift=center; LowPivot.broken=false;
   }
   if(HighPivot.time>0 && !HighPivot.broken && Rates[shift].close>HighPivot.price) {
      bool change=StructureBias<0;
      HighPivot.broken=true; StructureBreakCount++;
      StructureBias=1;
      AddBlock(shift,1,HighPivot.shift);
      if(draw && DrawStructureBreaks)
         StructureText(Prefix+"STRUCT_BOS_U_"+(string)(long)Rates[shift].time,Rates[shift].time,HighPivot.price,change ? "CHOCH UP" : "BOS UP",clrLimeGreen);
   }
   if(LowPivot.time>0 && !LowPivot.broken && Rates[shift].close<LowPivot.price) {
      bool change=StructureBias>0;
      LowPivot.broken=true; StructureBreakCount++;
      StructureBias=-1;
      AddBlock(shift,-1,LowPivot.shift);
      if(draw && DrawStructureBreaks)
         StructureText(Prefix+"STRUCT_BOS_D_"+(string)(long)Rates[shift].time,Rates[shift].time,LowPivot.price,change ? "CHOCH DOWN" : "BOS DOWN",clrTomato);
   }
}

double StructureLinePrice(const AZTPivot &older,const AZTPivot &newer,datetime at) {
   if(older.time<=0 || newer.time<=older.time) return 0;
   return newer.price+(newer.price-older.price)*
      (double)(at-newer.time)/(double)(newer.time-older.time);
}

bool StructureLineValid(const AZTPivot &older,const AZTPivot &newer,int shift,int side) {
   if(older.time<=0 || newer.time<=older.time || newer.shift-PivotBars<=shift) return false;
   // A rising support or falling resistance only. Both pivots existed before this candle.
   if(side*(newer.price-older.price)<=0) return false;
   for(int i=newer.shift-PivotBars;i>shift;i--) {
      double line=StructureLinePrice(older,newer,Rates[i].time);
      if(line<=0 || side*(Rates[i].close-line)<0) return false;
   }
   return true;
}

void FindStructureSetup(int shift,AZTStructureSignal &candidate) {
   ZeroMemory(candidate);
   if(!StructureATRValid(shift) || shift+1>=ArraySize(Rates)) return;
   ExpireStructurePivots(shift);
   double body=Rates[shift].close-Rates[shift].open;
   // Examine untouched blocks BEFORE this candle marks them mitigated.
   if(EnableOrderBlockSignals) {
      for(int i=ArraySize(Blocks)-1;i>=0;i--) {
         if(Blocks[i].touched || Blocks[i].bornShift<=shift ||
            Blocks[i].bornShift-shift>MathMin(OBMaxAgeBars,StructureLookback)) continue;
         bool touch=Rates[shift].low<=Blocks[i].top && Rates[shift].high>=Blocks[i].bottom;
         bool rejection=Blocks[i].side==1 ? Rates[shift].close>Blocks[i].top && body>0
                                         : Rates[shift].close<Blocks[i].bottom && body<0;
         if(!touch || !rejection) continue;
         candidate.side=Blocks[i].side;
         candidate.setup="Fresh order-block rejection";
         candidate.stopAnchor=candidate.side==1 ? MathMin(Blocks[i].bottom,Rates[shift].low)
                                                : MathMax(Blocks[i].top,Rates[shift].high);
         candidate.zoneTop=Blocks[i].top; candidate.zoneBottom=Blocks[i].bottom;
         return;
      }
   }
   if(EnableStructureBreakSignals) {
      if(HighPivot.time>0 && !HighPivot.broken && Rates[shift].close>HighPivot.price &&
         Rates[shift+1].close<=HighPivot.price && body>=ATR[shift]*OBImpulseATR) {
         candidate.side=1;
         candidate.setup=StructureBias<0 ? "Bullish CHOCH impulse" : "Bullish BOS impulse";
         candidate.stopAnchor=LowPivot.time>0 ? MathMin(LowPivot.price,Rates[shift].low) : Rates[shift].low;
         candidate.zoneTop=HighPivot.price+0.2*ATR[shift]; candidate.zoneBottom=HighPivot.price-0.2*ATR[shift];
         return;
      }
      if(LowPivot.time>0 && !LowPivot.broken && Rates[shift].close<LowPivot.price &&
         Rates[shift+1].close>=LowPivot.price && -body>=ATR[shift]*OBImpulseATR) {
         candidate.side=-1;
         candidate.setup=StructureBias>0 ? "Bearish CHOCH impulse" : "Bearish BOS impulse";
         candidate.stopAnchor=HighPivot.time>0 ? MathMax(HighPivot.price,Rates[shift].high) : Rates[shift].high;
         candidate.zoneTop=LowPivot.price+0.2*ATR[shift]; candidate.zoneBottom=LowPivot.price-0.2*ATR[shift];
         return;
      }
   }
   if(!EnableTrendlineSignals) return;
   double tolerance=ATR[shift]*TrendlineToleranceATR;
   if(body>0 && StructureLineValid(PreviousLow,LowPivot,shift,1)) {
      double line=StructureLinePrice(PreviousLow,LowPivot,Rates[shift].time);
      if(line>0 && Rates[shift].low<=line+tolerance && Rates[shift].low>=line-tolerance &&
         Rates[shift].close>line) {
         candidate.side=1; candidate.setup="Rising trendline rejection";
         candidate.stopAnchor=MathMin(Rates[shift].low,LowPivot.price);
         candidate.zoneTop=line+tolerance; candidate.zoneBottom=line-tolerance;
         return;
      }
   }
   if(body<0 && StructureLineValid(PreviousHigh,HighPivot,shift,-1)) {
      double line=StructureLinePrice(PreviousHigh,HighPivot,Rates[shift].time);
      if(line>0 && Rates[shift].high>=line-tolerance && Rates[shift].high<=line+tolerance &&
         Rates[shift].close<line) {
         candidate.side=-1; candidate.setup="Falling trendline rejection";
         candidate.stopAnchor=MathMax(Rates[shift].high,HighPivot.price);
         candidate.zoneTop=line+tolerance; candidate.zoneBottom=line-tolerance;
      }
   }
}

void Trendline(string name, const AZTPivot &older, const AZTPivot &newer, color colour) {
   if(older.time<=0 || newer.time<=older.time) return;
   ObjectCreate(0,name,OBJ_TREND,0,older.time,older.price,newer.time,newer.price);
   ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,true);
   ObjectSetInteger(0,name,OBJPROP_COLOR,colour);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,"Last two confirmed swing pivots; signals require closed-candle rejection and configured filters");
}

void ResetStructure() {
   ZeroMemory(HighPivot); ZeroMemory(PreviousHigh); ZeroMemory(LowPivot); ZeroMemory(PreviousLow);
   ArrayResize(Blocks,0); StructureBreakCount=0; StructureBias=0;
}

void BuildStructureCache(bool draw=false) {
   ResetStructure();
   int count=ArraySize(Rates);
   ArrayResize(StructureSignals,count);
   for(int i=0;i<count;i++) ZeroMemory(StructureSignals[i]);
   // One linear chronological replay caches every setup. Evaluating historical
   // shift N never reads OHLC/ATR at N-1, N-2 or the forming bar at index 0.
   int oldest=count-2*PivotBars-1;
   for(int shift=oldest;shift>=1;shift--) {
      if(shift==StructureLookback) StructureBreakCount=0;
      FindStructureSetup(shift,StructureSignals[shift]);
      ProcessStructureBar(shift,draw && shift<=StructureLookback);
   }
   StructureCacheSize=count;
   StructureCacheTime=count>1 ? Rates[1].time : 0;
   StructureCacheReady=true;
}

bool EvaluateStructureSignal(int shift,int &side,string &setup,double &stopAnchor,string &reason) {
   side=0; setup=""; stopAnchor=0;
   if(shift<1 || shift+2*PivotBars+1>=ArraySize(Rates)) {
      reason="Waiting for confirmed structure history"; return false;
   }
   if(!StructureCacheReady || StructureCacheSize!=ArraySize(Rates) || StructureCacheTime!=Rates[1].time)
      BuildStructureCache(false);
   side=StructureSignals[shift].side;
   setup=StructureSignals[shift].setup;
   stopAnchor=StructureSignals[shift].stopAnchor;
   reason=side==0 ? "Waiting: fresh order-block, swing break or trendline rejection" : setup;
   return side!=0;
}

void RebuildStructure() {
   ObjectsDeleteAll(0,Prefix+"STRUCT_");
   BuildStructureCache(true);
   if(ArraySize(Rates)<2) { StructureStatus="Waiting for history"; return; }
   if(DrawTrendlines) {
      Trendline(Prefix+"STRUCT_RESISTANCE",PreviousHigh,HighPivot,clrTomato);
      Trendline(Prefix+"STRUCT_SUPPORT",PreviousLow,LowPivot,clrDeepSkyBlue);
   }
   datetime right=Rates[0].time+PeriodSeconds(TF)*StructureExtendBars;
   int fresh=0, touched=0;
   for(int i=0;i<ArraySize(Blocks);i++) {
      if(Blocks[i].touched) touched++; else fresh++;
      if(!DrawOrderBlocks) continue;
      string name=Prefix+"STRUCT_OB_"+(string)i;
      color colour=Blocks[i].touched ? clrSlateGray : Blocks[i].side==1 ? clrSeaGreen : clrIndianRed;
      ObjectCreate(0,name,OBJ_RECTANGLE,0,Blocks[i].origin,Blocks[i].top,right,Blocks[i].bottom);
      ObjectSetInteger(0,name,OBJPROP_COLOR,colour);
      ObjectSetInteger(0,name,OBJPROP_FILL,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
      ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
      string label=(Blocks[i].side==1 ? "BULL OB" : "BEAR OB")+(Blocks[i].touched ? " touched" : " fresh");
      ObjectSetString(0,name,OBJPROP_TOOLTIP,label+" | confirmed at close of "+TimeToString(Blocks[i].confirmed));
      StructureText(name+"_LABEL",Rates[0].time,Blocks[i].top,label,colour);
   }
   StructureStatus="OB fresh="+(string)fresh+" touched="+(string)touched+" | BOS="+(string)StructureBreakCount+
      " | pivot delay="+(string)PivotBars+" bars";
   ChartRedraw();
}
#endif
