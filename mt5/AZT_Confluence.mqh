// Confluence engine: classic tools that must agree with a rule-based signal.
// MACD, MA200, FVG, support/resistance from repeated swing touches (history
// repetition, S/R flips), Fibonacci retracement, candle patterns, double top/bottom.
// Causal: evaluating bar `shift` reads only bars >= shift (never bar 0).
// Include after LocalSignal and the Rates/ATR/MACD/TrendMA arrays.
#ifndef AZT_CONFLUENCE_MQH
#define AZT_CONFLUENCE_MQH

struct AZTLevel {
   double price;
   int touches;
   bool wasHigh, wasLow; // both => support/resistance flip
};

bool ConfluenceBar(int i) { return i>=1 && i<ArraySize(Rates); }

double ArrayAt(const double &values[], int i) {
   if(i<0 || i>=ArraySize(values)) return EMPTY_VALUE;
   double v=values[i];
   return (v==EMPTY_VALUE || !MathIsValidNumber(v)) ? EMPTY_VALUE : v;
}

// Strict swing pivot at `center`, confirmed by bars that closed no later than `shift`.
bool SwingPivot(int center, int shift, bool high) {
   if(center-PivotBars<shift || center+PivotBars>=ArraySize(Rates)) return false;
   double value=high ? Rates[center].high : Rates[center].low;
   for(int j=1;j<=PivotBars;j++) {
      if(high && (Rates[center-j].high>=value || Rates[center+j].high>=value)) return false;
      if(!high && (Rates[center-j].low<=value || Rates[center+j].low<=value)) return false;
   }
   return true;
}

// Levels touched by >= SNRMinTouches swing pivots inside SNRZoneATR.
int BuildLevels(int shift, double atr, AZTLevel &levels[]) {
   ArrayResize(levels,0);
   double prices[]; bool highs[];
   int last=MathMin(ArraySize(Rates)-PivotBars-1,shift+SNRLookback);
   for(int k=shift+PivotBars;k<=last;k++) {
      for(int h=0;h<2;h++) {
         if(!SwingPivot(k,shift,h==0)) continue;
         int n=ArraySize(prices); ArrayResize(prices,n+1); ArrayResize(highs,n+1);
         prices[n]=h==0 ? Rates[k].high : Rates[k].low; highs[n]=h==0;
      }
   }
   double zone=atr*SNRZoneATR;
   bool used[]; ArrayResize(used,ArraySize(prices)); ArrayInitialize(used,false);
   for(int i=0;i<ArraySize(prices);i++) {
      if(used[i]) continue;
      double sum=0; int touches=0; bool wasHigh=false, wasLow=false;
      for(int j=i;j<ArraySize(prices);j++) {
         if(used[j] || MathAbs(prices[j]-prices[i])>zone) continue;
         used[j]=true; sum+=prices[j]; touches++;
         if(highs[j]) wasHigh=true; else wasLow=true;
      }
      if(touches<SNRMinTouches) continue;
      int n=ArraySize(levels); ArrayResize(levels,n+1);
      levels[n].price=sum/touches; levels[n].touches=touches;
      levels[n].wasHigh=wasHigh; levels[n].wasLow=wasLow;
   }
   return ArraySize(levels);
}

// Most recent confirmed pivot (index) of a kind, or -1.
int LastPivot(int shift, bool high, int startFrom=0) {
   int last=MathMin(ArraySize(Rates)-PivotBars-1,shift+SNRLookback);
   for(int k=MathMax(shift+PivotBars,startFrom);k<=last;k++) if(SwingPivot(k,shift,high)) return k;
   return -1;
}

void AddFactor(string &text, int &score, int vote, string label) {
   score+=vote;
   text+="\n"+(vote>0 ? "✅ " : vote<0 ? "⚠️ " : "• ")+label;
}

// Scores the setup. Returns false (with `blocker`) when a strong opposing
// level sits between entry and TP1 and BlockIfLevelBeforeTP1 is on.
bool EvaluateConfluence(int shift, int side, double entry, double sl, int &score, string &factors, string &blocker) {
   score=0; factors=""; blocker="";
   double atr=ArrayAt(ATR,shift);
   if(atr==EMPTY_VALUE || atr<=0) return true;
   double risk=MathAbs(entry-sl), tp1=entry+side*risk*TP1_R;
   string sideWord=side==1 ? "bullish" : "bearish";

   if(UseMACD) {
      double m0=ArrayAt(MACDMain,shift), m1=ArrayAt(MACDMain,shift+1), s0=ArrayAt(MACDSignal,shift);
      if(m0!=EMPTY_VALUE && m1!=EMPTY_VALUE && s0!=EMPTY_VALUE) {
         int vote=(m0>s0 && m0>m1) ? 1 : (m0<s0 && m0<m1) ? -1 : 0;
         AddFactor(factors,score,vote*side,"MACD "+(vote==1 ? "bullish" : vote==-1 ? "bearish" : "neytral")+
            " ("+DoubleToString(m0,_Digits+1)+" / signal "+DoubleToString(s0,_Digits+1)+")");
      }
   }
   double ma=ArrayAt(TrendMA,shift);
   if(UseTrendMA && ma!=EMPTY_VALUE) {
      int vote=Rates[shift].close>ma ? 1 : -1;
      AddFactor(factors,score,vote*side,"Narx MA"+(string)TrendMAPeriod+" "+(vote==1 ? "ustida" : "ostida")+" ("+Price(ma)+")");
   }
   if(UseFVG) {
      // Bullish FVG: high of candle j+1 below low of candle j-1 (3-candle gap).
      for(int j=shift+2;j<=shift+FVGLookback && j+1<ArraySize(Rates);j++) {
         double bottom=side==1 ? Rates[j+1].high : Rates[j-1].high;
         double top=side==1 ? Rates[j-1].low : Rates[j+1].low;
         if(top-bottom<atr*FVGMinATR) continue;
         bool filled=false;
         for(int k=j-2;k>shift && !filled;k--)
            filled=side==1 ? Rates[k].low<=bottom : Rates[k].high>=top;
         if(filled) continue;
         bool reacted=side==1 ? (Rates[shift].low<=top && Rates[shift].close>bottom)
                              : (Rates[shift].high>=bottom && Rates[shift].close<top);
         if(reacted) { AddFactor(factors,score,1,sideWord+" FVG "+Price(bottom)+"-"+Price(top)+" dan reaksiya"); break; }
      }
      for(int j=shift+2;j<=shift+FVGLookback && j+1<ArraySize(Rates);j++) {
         // Opposite, unfilled FVG in the way to TP1.
         double bottom=side==1 ? Rates[j-1].high : Rates[j+1].high;
         double top=side==1 ? Rates[j+1].low : Rates[j-1].low;
         if(top-bottom<atr*FVGMinATR) continue;
         bool filled=false;
         for(int k=j-2;k>=shift && !filled;k--)
            filled=side==1 ? Rates[k].high>=top : Rates[k].low<=bottom;
         if(filled) continue;
         double nearEdge=side==1 ? bottom : top;
         if(side*(nearEdge-entry)>0 && side*(tp1-nearEdge)>0) {
            AddFactor(factors,score,-1,"Qarshi FVG "+Price(bottom)+"-"+Price(top)+" TP1 yo'lida");
            break;
         }
      }
   }
   AZTLevel levels[];
   if(UseSNR && BuildLevels(shift,atr,levels)>0) {
      double zone=atr*SNRZoneATR;
      for(int i=0;i<ArraySize(levels);i++) {
         double level=levels[i].price;
         string kind=(levels[i].wasHigh && levels[i].wasLow) ? (side==1 ? " (RBS: resistance→support)" : " (SBR: support→resistance)") : "";
         bool touched=side==1 ? (Rates[shift].low<=level+zone && Rates[shift].close>level)
                              : (Rates[shift].high>=level-zone && Rates[shift].close<level);
         if(touched) AddFactor(factors,score,1,(side==1 ? "Support " : "Resistance ")+Price(level)+
                                                " — tarixda "+(string)levels[i].touches+" marta qaytgan"+kind);
         bool ahead=side*(level-entry)>risk*0.25 && side*(tp1-level)>0;
         if(ahead) {
            string text=(side==1 ? "Resistance " : "Support ")+Price(level)+" ("+(string)levels[i].touches+
                        " marta) TP1 dan oldin turibdi";
            AddFactor(factors,score,-1,text);
            if(BlockIfLevelBeforeTP1 && levels[i].touches>=SNRMinTouches+1) blocker=text;
         }
      }
   }
   if(UseFibonacci) {
      // Impulse leg: for BUY the newest swing high and the swing low before it.
      int end=LastPivot(shift,side==1);
      int start=end>=0 ? LastPivot(shift,side!=1,end+1) : -1;
      if(end>=0 && start>=0) {
         double from=side==1 ? Rates[start].low : Rates[start].high;
         double to=side==1 ? Rates[end].high : Rates[end].low;
         double leg=MathAbs(to-from);
         if(leg>0 && side*(to-entry)>0 && side*(entry-from)>0) {
            double retrace=MathAbs(to-entry)/leg;
            int vote=(retrace>=0.5 && retrace<=0.786) ? 1 : 0;
            AddFactor(factors,score,vote,"Fibonacci qaytish "+DoubleToString(retrace*100,1)+"%"+
               (vote>0 ? " (oltin zona 50-78.6%)" : "")+" | kengaytma 1.272: "+Price(from+side*leg*1.272)+
               ", 1.618: "+Price(from+side*leg*1.618));
         }
      }
   }
   if(UsePatterns && ConfluenceBar(shift+1)) {
      MqlRates c=Rates[shift], p=Rates[shift+1];
      double body=MathAbs(c.close-c.open), range=c.high-c.low;
      double lowerWick=MathMin(c.open,c.close)-c.low, upperWick=c.high-MathMax(c.open,c.close);
      bool engulf=side==1 ? (p.close<p.open && c.close>c.open && c.close>=p.open && c.open<=p.close)
                          : (p.close>p.open && c.close<c.open && c.close<=p.open && c.open>=p.close);
      bool pin=range>0 && (side==1 ? (lowerWick>=2*body && lowerWick>=0.5*range && c.close>=c.low+range*0.6)
                                   : (upperWick>=2*body && upperWick>=0.5*range && c.close<=c.high-range*0.6));
      if(engulf) AddFactor(factors,score,1,(side==1 ? "Bullish" : "Bearish")+string(" engulfing sham"));
      else if(pin) AddFactor(factors,score,1,side==1 ? "Pin bar / hammer" : "Pin bar / shooting star");
      int a=LastPivot(shift,side!=1), b=a>=0 ? LastPivot(shift,side!=1,a+1) : -1;
      if(a>=0 && b>=0) {
         double pa=side==1 ? Rates[a].low : Rates[a].high, pb=side==1 ? Rates[b].low : Rates[b].high;
         if(MathAbs(pa-pb)<=atr*SNRZoneATR) AddFactor(factors,score,1,(side==1 ? "Double bottom " : "Double top ")+Price((pa+pb)/2));
      }
   }
   double rsi=ArrayAt(RSI,shift);
   if(rsi!=EMPTY_VALUE) AddFactor(factors,score,0,"RSI "+DoubleToString(rsi,1));
   return blocker=="";
}
#endif
