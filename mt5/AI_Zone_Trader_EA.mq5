// MT5-only signals. No server, webhook or API key required.
#property strict
#property version "1.10"
#property description "Closed-candle EMA/RSI signals. Automatic orders are OFF by default."
#include <Trade/Trade.mqh>

input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_CURRENT;
input int FastEMA = 21;
input int SlowEMA = 55;
input int RSIPeriod = 14;
input int ATRPeriod = 14;
input bool EnableCrossSignals = true;
input bool EnablePullbackSignals = true;
input double RSIBuyMin = 50.0;
input double RSIBuyMax = 70.0;
input double RSISellMin = 30.0;
input double RSISellMax = 50.0;
input int CooldownBars = 3;
input int SwingLookback = 10;
input double StopATR = 1.5;
input double TP1_R = 1.2;
input double TP2_R = 2.0;
input double TP3_R = 3.0;
input int HistoryBars = 200;            // Historical arrows only; no old orders/alerts
input bool PopupAlerts = true;
input bool PushNotifications = false; // Configure MT5 Notifications first
input bool DrawLevels = true;
input bool DrawTrendlines = true;
input bool DrawOrderBlocks = true;
input bool DrawStructureBreaks = true;
input int StructureLookback = 500;
input int PivotBars = 3;               // Left AND right confirmation candles
input int OBSearchBars = 20;
input double OBImpulseATR = 0.8;       // Breakout candle body / ATR
input int MaxOrderBlocks = 8;
input int OBMaxAgeBars = 200;
input int StructureExtendBars = 20;
input bool EnableAutoTrading = false;
input double MaxRiskPercent = 0.50;
input double MaxDailyLossPercent = 2.0;
input double MaxDrawdownPercent = 10.0;
input int MaxConsecutiveLosses = 3;
input int MaxOpenPositions = 1;        // Account-wide positions + pending orders
input double MaxSpreadPoints = 18.0;   // AUTO ORDERS ONLY, broker points
input double MaxEntryDriftATR = 0.5;
input int SlippagePoints = 30;
input ulong MagicNumber = 260916;

CTrade Trade;
int FastHandle=INVALID_HANDLE, SlowHandle=INVALID_HANDLE;
int RSIHandle=INVALID_HANDLE, ATRHandle=INVALID_HANDLE;
ENUM_TIMEFRAMES TF;
MqlRates Rates[];
double Fast[], Slow[], RSI[], ATR[];
datetime LastClosedBar=0, LastSignalBar=0;
bool Ready=false;
string Prefix, Status="Starting", LastSignal="none", TradeStatus="";
int HistoricalSignals=0;

#include "AZT_Structure.mqh"

struct LocalSignal {
   int side; // 1 = BUY, -1 = SELL
   datetime time;
   double entry, sl, tp1, tp2, tp3, atr;
   string setup;
};

int RequiredBars() {
   return MathMax(SlowEMA*3,MathMax(RSIPeriod,ATRPeriod)*3)+SwingLookback+3;
}

double TickPrice(double price, int direction=0) {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(step<=0) step=_Point;
   double units=price/step;
   double rounded=(direction<0 ? MathFloor(units) : direction>0 ? MathCeil(units) : MathRound(units));
   return NormalizeDouble(rounded*step,_Digits);
}

bool LoadData(int count) {
   // Series arrays: 0 = forming candle, 1 = last CLOSED candle.
   if(BarsCalculated(FastHandle)<count || BarsCalculated(SlowHandle)<count ||
      BarsCalculated(RSIHandle)<count || BarsCalculated(ATRHandle)<count) return false;
   return CopyRates(_Symbol,TF,0,count,Rates)==count &&
          CopyBuffer(FastHandle,0,0,count,Fast)==count &&
          CopyBuffer(SlowHandle,0,0,count,Slow)==count &&
          CopyBuffer(RSIHandle,0,0,count,RSI)==count &&
          CopyBuffer(ATRHandle,0,0,count,ATR)==count;
}

bool EvaluateSignal(int shift, LocalSignal &signal, string &reason) {
   if(shift<1 || shift+SwingLookback>=ArraySize(Rates)) { reason="Waiting for history"; return false; }
   if(ATR[shift]<=0 || ATR[shift]==EMPTY_VALUE || Fast[shift]==EMPTY_VALUE ||
      Slow[shift]==EMPTY_VALUE || RSI[shift]==EMPTY_VALUE) { reason="Indicators warming up"; return false; }
   bool up=Fast[shift]>Slow[shift] && Rates[shift].close>Fast[shift];
   bool down=Fast[shift]<Slow[shift] && Rates[shift].close<Fast[shift];
   int side=up ? 1 : down ? -1 : 0;
   if(side==0) { reason="Waiting: price and EMA trend disagree"; return false; }
   double momentum=RSI[shift];
   if((side==1 && !(momentum>RSIBuyMin && momentum<RSIBuyMax)) ||
      (side==-1 && !(momentum>RSISellMin && momentum<RSISellMax))) {
      reason="Waiting: RSI filter ("+DoubleToString(momentum,1)+")"; return false;
   }
   bool cross=side==1 ? Fast[shift+1]<=Slow[shift+1] : Fast[shift+1]>=Slow[shift+1];
   bool pullback=side==1 ? (Rates[shift].low<=Fast[shift] && Rates[shift].close>Rates[shift].open)
                        : (Rates[shift].high>=Fast[shift] && Rates[shift].close<Rates[shift].open);
   if(!(EnableCrossSignals && cross) && !(EnablePullbackSignals && pullback)) {
      reason="Waiting: EMA crossover or pullback"; return false;
   }
   signal.side=side; signal.time=Rates[shift].time; signal.atr=ATR[shift];
   signal.setup=(EnableCrossSignals && cross) ? "EMA cross" : "EMA pullback";
   signal.entry=TickPrice(Rates[shift].close);
   double extreme=(side==1 ? Rates[shift].low : Rates[shift].high);
   for(int i=shift+1;i<shift+SwingLookback;i++)
      extreme=side==1 ? MathMin(extreme,Rates[i].low) : MathMax(extreme,Rates[i].high);
   double distance=MathMax(StopATR*signal.atr,MathAbs(signal.entry-extreme)+0.2*signal.atr);
   signal.sl=TickPrice(signal.entry-side*distance,-side);
   distance=MathAbs(signal.entry-signal.sl);
   signal.tp1=TickPrice(signal.entry+side*distance*TP1_R,side);
   signal.tp2=TickPrice(signal.entry+side*distance*TP2_R,side);
   signal.tp3=TickPrice(signal.entry+side*distance*TP3_R,side);
   if(signal.sl<=0 || signal.tp3<=0 || distance<=0) { reason="Invalid price levels"; return false; }
   reason=signal.setup;
   return true;
}

bool CoolingDown(int shift) {
   if(LastSignalBar==0 || CooldownBars==0) return false;
   int previous=iBarShift(_Symbol,TF,LastSignalBar,true);
   return previous>=shift && previous-shift<CooldownBars;
}

string Price(double value) { return DoubleToString(value,_Digits); }

void Level(string suffix, double price, color colour) {
   string name=Prefix+suffix;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_HLINE,0,0,price);
   ObjectSetDouble(0,name,OBJPROP_PRICE,price);
   ObjectSetInteger(0,name,OBJPROP_COLOR,colour);
   ObjectSetInteger(0,name,OBJPROP_STYLE,STYLE_DOT);
   ObjectSetString(0,name,OBJPROP_TEXT,suffix);
}

void DrawSignal(const LocalSignal &signal, bool historical) {
   string side=signal.side==1 ? "BUY" : "SELL";
   string name=Prefix+"S_"+(string)(long)signal.time;
   double at=signal.entry-signal.side*0.3*signal.atr;
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,signal.side==1 ? OBJ_ARROW_BUY : OBJ_ARROW_SELL,0,signal.time,at);
   ObjectSetString(0,name,OBJPROP_TOOLTIP,(historical ? "HISTORICAL " : "LIVE ")+side+" "+
      TimeToString(signal.time)+" | "+signal.setup+" | Entry "+Price(signal.entry)+" | SL "+Price(signal.sl));
   if(DrawLevels) {
      Level("Entry",signal.entry,clrGold); Level("SL",signal.sl,clrTomato);
      Level("TP1",signal.tp1,clrLimeGreen); Level("TP2",signal.tp2,clrLimeGreen); Level("TP3",signal.tp3,clrLimeGreen);
   }
   LastSignal=(historical ? "History: " : "Live: ")+side+" "+TimeToString(signal.time)+
              " | Entry "+Price(signal.entry)+" SL "+Price(signal.sl)+
              "\nTP1 "+Price(signal.tp1)+" TP2 "+Price(signal.tp2)+" TP3 "+Price(signal.tp3);
}

void Panel() {
   MqlTick tick;
   string spread="waiting";
   if(SymbolInfoTick(_Symbol,tick) && tick.ask>0 && tick.bid>0)
      spread=DoubleToString((tick.ask-tick.bid)/_Point,1)+" points";
   string connection=TerminalInfoInteger(TERMINAL_CONNECTED) ? "connected" : "DISCONNECTED";
   if(MQLInfoInteger(MQL_TESTER)) connection="Strategy Tester";
   Comment("AI Zone Trader | MT5 ONLY | ",_Symbol," ",EnumToString(TF),
      "\nMode: ",EnableAutoTrading ? "AUTO TRADING" : "SIGNALS ONLY", " | ",connection,
      "\n",Status,"\nLast closed candle: ",TimeToString(LastClosedBar),
      "\nSpread: ",spread," | Order limit: ",DoubleToString(MaxSpreadPoints,1),
      "\nHistorical signals: ",HistoricalSignals,"\nLast signal: ",LastSignal,
      "\nStructure: ",StructureStatus,
      "\n",TradeStatus);
}

bool DailyRiskSafe(string &reason) {
   datetime start=StringToTime(TimeToString(TimeCurrent(),TIME_DATE));
   if(!HistorySelect(start,TimeCurrent())) { reason="Cannot read account history"; return false; }
   double net=0;
   int streak=0;
   bool latestStreak=true;
   for(int i=HistoryDealsTotal()-1;i>=0;i--) {
      ulong ticket=HistoryDealGetTicket(i);
      // Account-wide P/L includes entry commissions and fees.
      long type=HistoryDealGetInteger(ticket,DEAL_TYPE);
      if(type!=DEAL_TYPE_BUY && type!=DEAL_TYPE_SELL) continue;
      double pnl=HistoryDealGetDouble(ticket,DEAL_PROFIT)+HistoryDealGetDouble(ticket,DEAL_SWAP)+
                 HistoryDealGetDouble(ticket,DEAL_COMMISSION)+HistoryDealGetDouble(ticket,DEAL_FEE);
      net+=pnl;
      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(latestStreak && (entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY || entry==DEAL_ENTRY_INOUT)) {
         if(pnl<0) streak++;
         else if(pnl>0) latestStreak=false;
      }
   }
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0) { reason="Account balance is zero"; return false; }
   if(-net>=balance*MaxDailyLossPercent/100.0) { reason="Daily loss limit"; return false; }
   if(streak>=MaxConsecutiveLosses) { reason="Consecutive loss limit"; return false; }
   return true;
}

bool AutoOrder(const LocalSignal &signal, string &reason) {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) {
      reason="Algo Trading or account trading permission is OFF"; return false;
   }
   if(PositionSelect(_Symbol) || PositionsTotal()+OrdersTotal()>=MaxOpenPositions) {
      reason="Open position/pending order limit"; return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0) { reason="No quote"; return false; }
   if((tick.ask-tick.bid)/_Point>MaxSpreadPoints) { reason="Spread exceeds MaxSpreadPoints"; return false; }
   double balance=AccountInfoDouble(ACCOUNT_BALANCE), equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance<=0 || equity<=0) { reason="No account funds"; return false; }
   if((balance-equity)/balance*100.0>=MaxDrawdownPercent) { reason="Drawdown limit"; return false; }
   if(!DailyRiskSafe(reason)) return false;
   double entry=signal.side==1 ? tick.ask : tick.bid;
   if(MathAbs(entry-signal.entry)>signal.atr*MaxEntryDriftATR) { reason="Price moved too far from signal"; return false; }
   double distance=signal.side*(entry-signal.sl);
   double minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double marketClose=signal.side==1 ? tick.bid : tick.ask;
   if(distance<=0 || signal.side*(marketClose-signal.sl)<=minStop) { reason="SL violates broker stop distance"; return false; }
   // One broker TP at TP3; TP1 and TP2 are reference levels, not partial closes.
   double tp=TickPrice(entry+signal.side*distance*TP3_R,signal.side);
   if(tp<=0 || signal.side*(tp-marketClose)<=minStop) { reason="TP violates broker stop distance"; return false; }
   ENUM_ORDER_TYPE type=signal.side==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double loss=0;
   if(!OrderCalcProfit(type,_Symbol,1.0,entry,signal.sl,loss) || loss>=0) { reason="Cannot calculate SL risk"; return false; }
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP), minLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0 || minLot<=0 || maxLot<minLot) { reason="Invalid broker volume limits"; return false; }
   double budget=MathMin(balance,equity)*MaxRiskPercent/100.0;
   double volume=NormalizeDouble(MathFloor(MathMin(budget/MathAbs(loss),maxLot)/step)*step,8);
   if(volume<minLot) { reason="Risk budget below minimum lot; order skipped"; return false; }
   double margin=0;
   if(!OrderCalcMargin(type,_Symbol,volume,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      reason="Insufficient free margin"; return false;
   }
   Trade.SetTypeFillingBySymbol(_Symbol);
   string comment="AZT-L-"+(string)(long)signal.time;
   bool sent=signal.side==1 ? Trade.Buy(volume,_Symbol,entry,signal.sl,tp,comment)
                           : Trade.Sell(volume,_Symbol,entry,signal.sl,tp,comment);
   uint code=Trade.ResultRetcode();
   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL && code!=TRADE_RETCODE_PLACED)) {
      reason="Broker: "+(string)code+" "+Trade.ResultRetcodeDescription(); return false;
   }
   reason="Order accepted | lots "+DoubleToString(volume,8)+" | SL "+Price(signal.sl)+" | TP "+Price(tp);
   return true;
}

void Scan() {
   if(!Ready) {
      int count=RequiredBars()+MathMax(HistoryBars,StructureLookback);
      int available=Bars(_Symbol,TF);
      if(available<RequiredBars()) {
         CopyRates(_Symbol,TF,0,RequiredBars(),Rates);
         Status="Waiting for price history"; Panel(); return;
      }
      count=MathMin(count,available);
      if(!LoadData(count)) { Status="Waiting for indicator data"; Panel(); return; }
      RebuildStructure();
      int oldest=MathMin(HistoryBars,count-RequiredBars());
      for(int i=oldest;i>=1;i--) {
         LocalSignal signal; string reason;
         if(EvaluateSignal(i,signal,reason) && !CoolingDown(i)) {
            DrawSignal(signal,true); LastSignalBar=signal.time; HistoricalSignals++;
         }
      }
      LastClosedBar=Rates[1].time;
      Ready=true;
      Status="Ready: waiting for the next candle close";
      Print("AZT MT5-only ready: ",_Symbol," ",EnumToString(TF),"; historical signals=",HistoricalSignals,
            "; auto trading=",EnableAutoTrading,". Historical signals never trigger orders/alerts.");
      Panel(); return;
   }
   datetime closed=iTime(_Symbol,TF,1);
   if(closed<=0 || closed==LastClosedBar) { Panel(); return; }
   int count=MathMin(Bars(_Symbol,TF),RequiredBars()+StructureLookback);
   if(count<RequiredBars() || !LoadData(count)) { Status="Waiting for indicator data; will retry"; Panel(); return; }
   RebuildStructure();
   // Only mark processed after all data is ready; shared OnTick/OnTimer guard.
   LastClosedBar=Rates[1].time;
   LocalSignal signal; string reason;
   if(!EvaluateSignal(1,signal,reason)) { Status=reason; Print("AZT: ",Status); Panel(); return; }
   if(CoolingDown(1)) { Status="Waiting: signal cooldown"; Panel(); return; }
   LastSignalBar=signal.time;
   DrawSignal(signal,false);
   Status=(signal.side==1 ? "BUY" : "SELL")+string(" signal: ")+signal.setup;
   string message="AZT "+_Symbol+" "+EnumToString(TF)+" "+Status+" | "+TimeToString(signal.time)+
      " | Entry "+Price(signal.entry)+" SL "+Price(signal.sl)+
      " TP1 "+Price(signal.tp1)+" TP2 "+Price(signal.tp2)+" TP3 "+Price(signal.tp3);
   Print(message);
   if(!MQLInfoInteger(MQL_TESTER)) {
      if(PopupAlerts) Alert(message);
      if(PushNotifications && !SendNotification(message)) Print("Push notification failed: ",GetLastError());
   }
   TradeStatus="Signals only: automatic orders are OFF";
   if(EnableAutoTrading) {
      if(TimeCurrent()-iTime(_Symbol,TF,0)>30) TradeStatus="Order skipped: signal received more than 30 seconds late";
      else {
         bool ok=AutoOrder(signal,reason);
         TradeStatus=(ok ? "" : "Order skipped: ")+reason;
      }
      Print("AZT: ",TradeStatus);
   }
   Panel(); ChartRedraw();
}

int OnInit() {
   if(FastEMA<2 || SlowEMA<=FastEMA || SlowEMA>1000 || RSIPeriod<2 || RSIPeriod>1000 ||
      ATRPeriod<2 || ATRPeriod>1000 || SwingLookback<1 || SwingLookback>500 ||
      HistoryBars<0 || HistoryBars>2000 || CooldownBars<0 || StopATR<=0 ||
      StructureLookback<50 || StructureLookback>2000 || PivotBars<1 || PivotBars>20 ||
      OBSearchBars<1 || OBSearchBars>100 || OBImpulseATR<=0 || MaxOrderBlocks<1 || MaxOrderBlocks>30 ||
      OBMaxAgeBars<1 || OBMaxAgeBars>2000 || StructureExtendBars<1 || StructureExtendBars>100 ||
      TP1_R<=0 || TP2_R<TP1_R || TP3_R<TP2_R ||
      RSIBuyMin<0 || RSIBuyMax>100 || RSIBuyMin>=RSIBuyMax ||
      RSISellMin<0 || RSISellMax>100 || RSISellMin>=RSISellMax ||
      (!EnableCrossSignals && !EnablePullbackSignals) || MaxRiskPercent<=0 || MaxRiskPercent>100 ||
      MaxDailyLossPercent<=0 || MaxDrawdownPercent<=0 || MaxConsecutiveLosses<1 ||
      MaxOpenPositions<1 || MaxSpreadPoints<=0 || MaxEntryDriftATR<=0 || SlippagePoints<0) {
      Print("AZT: Invalid input parameters"); return INIT_PARAMETERS_INCORRECT;
   }
   TF=SignalTimeframe==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : SignalTimeframe;
   Prefix="AZT_LOCAL_"+(string)MagicNumber+"_";
   ArraySetAsSeries(Rates,true); ArraySetAsSeries(Fast,true); ArraySetAsSeries(Slow,true);
   ArraySetAsSeries(RSI,true); ArraySetAsSeries(ATR,true);
   FastHandle=iMA(_Symbol,TF,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   SlowHandle=iMA(_Symbol,TF,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   RSIHandle=iRSI(_Symbol,TF,RSIPeriod,PRICE_CLOSE); ATRHandle=iATR(_Symbol,TF,ATRPeriod);
   if(FastHandle==INVALID_HANDLE || SlowHandle==INVALID_HANDLE || RSIHandle==INVALID_HANDLE || ATRHandle==INVALID_HANDLE) {
      Print("AZT: Cannot create indicators: ",GetLastError()); return INIT_FAILED;
   }
   Trade.SetExpertMagicNumber(MagicNumber); Trade.SetDeviationInPoints(SlippagePoints);
   Trade.SetAsyncMode(false);
   if(!EventSetTimer(2)) { Print("AZT: Cannot start timer"); return INIT_FAILED; }
   TradeStatus=EnableAutoTrading ? "Auto orders enabled; risk checks apply" : "Signals only: automatic orders are OFF";
   Panel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   if(FastHandle!=INVALID_HANDLE) IndicatorRelease(FastHandle);
   if(SlowHandle!=INVALID_HANDLE) IndicatorRelease(SlowHandle);
   if(RSIHandle!=INVALID_HANDLE) IndicatorRelease(RSIHandle);
   if(ATRHandle!=INVALID_HANDLE) IndicatorRelease(ATRHandle);
   if(Prefix!="") ObjectsDeleteAll(0,Prefix);
   Comment("");
}
void OnTimer() { Scan(); }
void OnTick() { Scan(); }
