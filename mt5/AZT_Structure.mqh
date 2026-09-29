// Deterministic chart structure. Included after EA inputs and Rates/ATR globals.
// An OB here is a candle-range heuristic, not evidence of institutional orders.
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
      if(broken || Blocks[i].bornShift-shift>OBMaxAgeBars) { RemoveBlock(i); continue; }
      if(Rates[shift].low<=Blocks[i].top && Rates[shift].high>=Blocks[i].bottom) Blocks[i].touched=true;
   }
}

bool AddBlock(int shift, int side, int pivotShift) {
   if(shift<1 || shift>=ArraySize(ATR) || ATR[shift]<=0 || ATR[shift]==EMPTY_VALUE) return false;
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
      HighPivot.broken=true; StructureBreakCount++;
      AddBlock(shift,1,HighPivot.shift);
      if(draw && DrawStructureBreaks)
         StructureText(Prefix+"STRUCT_BOS_U_"+(string)(long)Rates[shift].time,Rates[shift].time,HighPivot.price,"BOS UP",clrLimeGreen);
   }
   if(LowPivot.time>0 && !LowPivot.broken && Rates[shift].close<LowPivot.price) {
      LowPivot.broken=true; StructureBreakCount++;
      AddBlock(shift,-1,LowPivot.shift);
      if(draw && DrawStructureBreaks)
         StructureText(Prefix+"STRUCT_BOS_D_"+(string)(long)Rates[shift].time,Rates[shift].time,LowPivot.price,"BOS DOWN",clrTomato);
   }
}

void Trendline(string name, const AZTPivot &older, const AZTPivot &newer, color colour) {
   if(older.time<=0 || newer.time<=older.time) return;
   ObjectCreate(0,name,OBJ_TREND,0,older.time,older.price,newer.time,newer.price);
   ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,true);
   ObjectSetInteger(0,name,OBJPROP_COLOR,colour);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,"Last two confirmed swing pivots; projection is not a trade signal");
}

void ResetStructure() {
   ZeroMemory(HighPivot); ZeroMemory(PreviousHigh); ZeroMemory(LowPivot); ZeroMemory(PreviousLow);
   ArrayResize(Blocks,0); StructureBreakCount=0;
}

void RebuildStructure() {
   ObjectsDeleteAll(0,Prefix+"STRUCT_");
   ResetStructure();
   if(!DrawTrendlines && !DrawOrderBlocks && !DrawStructureBreaks) { StructureStatus="Drawing OFF"; return; }
   // Replay oldest to newest. At each step only candles already closed at that step are read.
   int oldest=MathMin(StructureLookback,ArraySize(Rates)-2*PivotBars-1);
   for(int shift=oldest;shift>=1;shift--) ProcessStructureBar(shift);
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
