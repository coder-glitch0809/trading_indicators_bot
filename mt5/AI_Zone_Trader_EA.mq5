// AI Zone Trader: everything runs inside MetaTrader 5.
// Rule-based signals -> Claude review (they learn from their own record)
// -> Telegram signal / approval buttons -> order with SL and 3-part take profit.
#property strict
#property version "4.00"
#property description "MT5 signals + Claude review + Telegram approval. SL and 3-part TP (50% at 1.5R, 25% at 2.25R, 25% at 3R)."
#include <Trade/Trade.mqh>

enum AZTTradeMode {
   AZT_SIGNALS_ONLY=0,   // Faqat signal: savdo ochilmaydi
   AZT_CONFIRM_EVERY=1,  // Har savdo Telegram tugmasi bilan tasdiqlanadi
   AZT_AI_HYBRID=2       // Claude tasdiqlasa o'zi kiradi, aks holda sizdan so'raydi
};

input group "1. Savdo rejimi"
input AZTTradeMode TradeMode = AZT_AI_HYBRID;
input int ApprovalTimeoutMinutes = 15;  // Javob bo'lmasa signal bekor
input bool SkipWhenAIRejects = true;    // AI rad etsa: savdo ham, tugma ham yo'q

input group "2. Risk (kichik hisob uchun ham)"
input double MaxRiskPercent = 1.0;       // Har savdoda balansdan risk, %
input double MinLotMaxRiskPercent = 3.0; // Kichik hisob: min lot riski shu %gacha bo'lsa min lot bilan kiradi
input double MaxDailyLossPercent = 3.0;
input double MaxDrawdownPercent = 10.0;
input int MaxConsecutiveLosses = 3;
input int MaxOpenPositions = 3;          // Hisob bo'yicha pozitsiya + kutilayotgan orderlar
input double MaxSpreadPoints = 25.0;     // Broker point birligida
input double MaxEntryDriftATR = 0.5;     // Narx signaldan shuncha ATR qochsa kirmaydi
input int SlippagePoints = 30;
input ulong MagicNumber = 260916;

input group "3. Stop loss va 3 qismli take profit"
input double StopATR = 1.5;              // SL kamida shuncha ATR
input double SLBufferATR = 0.5;          // SL swing/zona chegarasidan shuncha ATR nari (eski 0.2: wick bilan tez urilardi)
input int SwingLookback = 10;            // SL oxirgi swing ortiga qo'yiladi
input double TP1_R = 1.5;                // TP1 = asosiy TP yo'lining 50%i
input double TP1ClosePercent = 50;       // TP1 da yopiladigan qism, %
input double TP2_R = 2.25;               // TP2 = yo'lning 75%i
input double TP2ClosePercent = 25;       // TP2 da yopiladigan qism, %
input double TP3_R = 3.0;                // Asosiy TP = risk x3 (brokerga qo'yiladi)
input bool MoveSLAfterTP = true;         // TP1 dan keyin SL -> Entry, TP2 dan keyin SL -> TP1

input group "4. Signal qoidalari"
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
input int MaxSignalDelaySeconds = 180;   // Kechikkan sham signal bermaydi
input bool EnableStructureBreakSignals = true;
input bool EnableOrderBlockSignals = true;
input bool EnableTrendlineSignals = true;
input double TrendlineToleranceATR = 0.25;
input int StructureLookback = 500;
input int PivotBars = 3;                 // Left AND right confirmation candles
input int OBSearchBars = 20;
input double OBImpulseATR = 0.8;         // Breakout candle body / ATR
input int MaxOrderBlocks = 8;
input int OBMaxAgeBars = 200;

input group "4b. Qo'shimcha indikatorlar (konfluens)"
input int MinConfluence = 2;             // Signal uchun kamida shuncha qo'shimcha tasdiq (minus qarshi)
input bool BlockIfLevelBeforeTP1 = true; // Kuchli qarshi daraja TP1 dan oldin bo'lsa signal yo'q
input bool UseMACD = true;
input int MACDFast = 12;
input int MACDSlow = 26;
input int MACDSignalPeriod = 9;
input bool UseTrendMA = true;
input int TrendMAPeriod = 200;           // Uzoq muddatli moving average (SMA)
input bool UseFVG = true;                // Fair Value Gap
input int FVGLookback = 50;
input double FVGMinATR = 0.15;
input bool UseSNR = true;                // Support/Resistance: tarixda qayta-qayta tegilgan darajalar
input int SNRLookback = 300;
input double SNRZoneATR = 0.3;
input int SNRMinTouches = 2;
input bool UseFibonacci = true;          // 50-78.6% qaytish zonasi
input bool UsePatterns = true;           // Engulfing, pin bar, double top/bottom

input group "5. AI uchun kontekst"
input ENUM_TIMEFRAMES AIHigherTF1 = PERIOD_H4;
input ENUM_TIMEFRAMES AIHigherTF2 = PERIOD_D1;
input int AICandles = 40;                // AI ga yuboriladigan yopilgan shamlar

input group "6. Grafik, ogohlantirish, tarix"
input bool PopupAlerts = true;
input bool PushNotifications = false;    // MT5 Notifications sozlangan bo'lsa
input bool DrawLevels = true;
input bool DrawTrendlines = true;
input bool DrawOrderBlocks = true;
input bool DrawStructureBreaks = true;
input int StructureExtendBars = 20;
input int HistoryBars = 1000;            // Closed-bar replay; no historical orders/alerts
input int HistoryMaxHoldingBars = 100;
input double HistoryRoundTripCostPoints = 0; // Zero = gross illustrative results

CTrade Trade;
int FastHandle=INVALID_HANDLE, SlowHandle=INVALID_HANDLE;
int RSIHandle=INVALID_HANDLE, ATRHandle=INVALID_HANDLE;
int MACDHandle=INVALID_HANDLE, TrendMAHandle=INVALID_HANDLE;
int HTFHandles[4]={INVALID_HANDLE,INVALID_HANDLE,INVALID_HANDLE,INVALID_HANDLE};
ENUM_TIMEFRAMES TF;
MqlRates Rates[];
double Fast[], Slow[], RSI[], ATR[], MACDMain[], MACDSignal[], TrendMA[];
datetime LastClosedBar=0, LastSignalBar=0;
bool Ready=false;
string Prefix, PosScope, Status="Starting", LastSignal="none", TradeStatus="", AITestStatus="";
int HistoricalSignals=0;

#include "AZT_Structure.mqh"
#include "AZT_Telegram.mqh"
#include "AZT_AI.mqh"

struct LocalSignal {
   int side; // 1 = BUY, -1 = SELL
   datetime time;
   double entry, sl, tp1, tp2, tp3, atr;
   double zoneTop, zoneBottom; // Kirish zonasi: narx shu oraliqda bo'lganda kiriladi
   string setup;
   int score;      // Confluence: agreeing minus opposing classic factors
   string factors; // One line per factor, for Telegram and the AI
};

struct PendingApproval {
   bool active;
   string id;
   LocalSignal signal;
   datetime expires; // TimeLocal
};
PendingApproval Pending;

int RequiredBars() {
   int indicators=MathMax(MathMax(SlowEMA*3,MACDSlow*3),MathMax(RSIPeriod,ATRPeriod)*3)+SwingLookback+3;
   indicators=MathMax(indicators,TrendMAPeriod+FVGLookback+3);
   return MathMax(indicators,StructureLookback+2*PivotBars+3);
}

double TickPrice(double price, int direction=0) {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(step<=0) step=_Point;
   double units=price/step;
   double rounded=(direction<0 ? MathFloor(units) : direction>0 ? MathCeil(units) : MathRound(units));
   return NormalizeDouble(rounded*step,_Digits);
}

string Price(double value) { return DoubleToString(value,_Digits); }

#include "AZT_Confluence.mqh"

bool LoadData(int count) {
   // Series arrays: 0 = forming candle, 1 = last CLOSED candle.
   if(BarsCalculated(FastHandle)<count || BarsCalculated(SlowHandle)<count ||
      BarsCalculated(RSIHandle)<count || BarsCalculated(ATRHandle)<count ||
      BarsCalculated(MACDHandle)<count || BarsCalculated(TrendMAHandle)<count) return false;
   bool loaded=CopyRates(_Symbol,TF,0,count,Rates)==count &&
          CopyBuffer(FastHandle,0,0,count,Fast)==count &&
          CopyBuffer(SlowHandle,0,0,count,Slow)==count &&
          CopyBuffer(RSIHandle,0,0,count,RSI)==count &&
          CopyBuffer(ATRHandle,0,0,count,ATR)==count &&
          CopyBuffer(MACDHandle,0,0,count,MACDMain)==count &&
          CopyBuffer(MACDHandle,1,0,count,MACDSignal)==count &&
          CopyBuffer(TrendMAHandle,0,0,count,TrendMA)==count;
   if(loaded) InvalidateStructureCache();
   return loaded;
}

bool EvaluateSignal(int shift, LocalSignal &signal, string &reason) {
   if(shift<1 || shift+MathMax(SwingLookback,1)>=ArraySize(Rates) ||
      shift+1>=ArraySize(Fast) || shift+1>=ArraySize(Slow) ||
      shift>=ArraySize(RSI) || shift>=ArraySize(ATR)) { reason="Waiting for history"; return false; }
   if(ATR[shift]<=0 || ATR[shift]==EMPTY_VALUE || Fast[shift]==EMPTY_VALUE ||
      Slow[shift]==EMPTY_VALUE || RSI[shift]==EMPTY_VALUE ||
      Fast[shift+1]==EMPTY_VALUE || Slow[shift+1]==EMPTY_VALUE ||
      !MathIsValidNumber(ATR[shift]) || !MathIsValidNumber(Fast[shift]) ||
      !MathIsValidNumber(Slow[shift]) || !MathIsValidNumber(RSI[shift])) { reason="Indicators warming up"; return false; }
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
   int structureSide=0;
   string structureSetup, structureReason;
   double structureStop=0;
   bool structure=EvaluateStructureSignal(shift,structureSide,structureSetup,structureStop,structureReason);
   structure=structure && structureSide==side;
   if(!structure && !(EnableCrossSignals && cross) && !(EnablePullbackSignals && pullback)) {
      reason="Waiting: OB rejection, BOS, trendline or EMA setup"; return false;
   }
   signal.side=side; signal.time=Rates[shift].time; signal.atr=ATR[shift];
   signal.setup=structure ? structureSetup : (EnableCrossSignals && cross) ? "EMA cross" : "EMA pullback";
   signal.entry=TickPrice(Rates[shift].close);
   // Entry zone: the structure zone (OB, broken level, trendline), else the EMA21 band.
   signal.zoneTop=Fast[shift]+0.25*signal.atr; signal.zoneBottom=Fast[shift]-0.25*signal.atr;
   if(structure) { signal.zoneTop=StructureSignals[shift].zoneTop; signal.zoneBottom=StructureSignals[shift].zoneBottom; }
   double extreme=(side==1 ? Rates[shift].low : Rates[shift].high);
   for(int i=shift+1;i<shift+SwingLookback;i++)
      extreme=side==1 ? MathMin(extreme,Rates[i].low) : MathMax(extreme,Rates[i].high);
   if(structure && structureStop>0)
      extreme=side==1 ? MathMin(extreme,structureStop) : MathMax(extreme,structureStop);
   double distance=MathMax(StopATR*signal.atr,MathAbs(signal.entry-extreme)+SLBufferATR*signal.atr);
   signal.sl=TickPrice(signal.entry-side*distance,-side);
   distance=MathAbs(signal.entry-signal.sl);
   signal.tp1=TickPrice(signal.entry+side*distance*TP1_R,side);
   signal.tp2=TickPrice(signal.entry+side*distance*TP2_R,side);
   signal.tp3=TickPrice(signal.entry+side*distance*TP3_R,side);
   if(signal.sl<=0 || signal.tp3<=0 || distance<=0) { reason="Invalid price levels"; return false; }
   string blocker;
   if(!EvaluateConfluence(shift,side,signal.entry,signal.sl,signal.score,signal.factors,blocker)) {
      reason="Skipped "+signal.setup+": "+blocker; return false;
   }
   if(signal.score<MinConfluence) {
      reason="Skipped "+signal.setup+": confluence "+(string)signal.score+" < "+(string)MinConfluence; return false;
   }
   reason=signal.setup;
   return true;
}

bool CoolingDown(int shift) {
   if(LastSignalBar==0 || CooldownBars==0) return false;
   int previous=iBarShift(_Symbol,TF,LastSignalBar,true);
   return previous>=shift && previous-shift<CooldownBars;
}

// "200 pt = 20.0 pips" (pips only for 3/5-digit quotes, where the term is unambiguous).
string Distance(double priceDistance) {
   double points=MathAbs(priceDistance)/_Point;
   string text=DoubleToString(points,0)+" pt";
   if(_Digits==3 || _Digits==5) text+=" = "+DoubleToString(points/10.0,1)+" pips";
   return text;
}

string Money(double value) { return DoubleToString(value,2)+" "+AccountInfoString(ACCOUNT_CURRENCY); }

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
      if(signal.zoneTop>0 && !historical) {
         string zone=Prefix+"Z_"+(string)(long)signal.time;
         ObjectDelete(0,zone);
         ObjectCreate(0,zone,OBJ_RECTANGLE,0,signal.time,signal.zoneTop,signal.time+PeriodSeconds(TF)*StructureExtendBars,signal.zoneBottom);
         ObjectSetInteger(0,zone,OBJPROP_COLOR,signal.side==1 ? clrSeaGreen : clrIndianRed);
         ObjectSetInteger(0,zone,OBJPROP_FILL,true); ObjectSetInteger(0,zone,OBJPROP_BACK,true);
         ObjectSetInteger(0,zone,OBJPROP_SELECTABLE,false);
         ObjectSetString(0,zone,OBJPROP_TOOLTIP,"Kirish zonasi | "+signal.setup);
      }
      Level("Entry",signal.entry,clrGold); Level("SL",signal.sl,clrTomato);
      Level("TP1 "+DoubleToString(TP1ClosePercent,0)+"%",signal.tp1,clrLimeGreen);
      Level("TP2 "+DoubleToString(TP2ClosePercent,0)+"%",signal.tp2,clrLimeGreen);
      Level("TP3",signal.tp3,clrLimeGreen);
   }
   LastSignal=(historical ? "History: " : "Live: ")+side+" "+TimeToString(signal.time)+
              " | Entry "+Price(signal.entry)+" SL "+Price(signal.sl)+
              "\nTP1 "+Price(signal.tp1)+" TP2 "+Price(signal.tp2)+" TP3 "+Price(signal.tp3);
}

#include "AZT_History.mqh"
#include "AZT_Journal.mqh"

string ModeName() {
   return TradeMode==AZT_SIGNALS_ONLY ? "FAQAT SIGNAL" :
          TradeMode==AZT_CONFIRM_EVERY ? "HAR SAVDO TASDIQ BILAN" : "AI HYBRID (Claude rozi bo'lsa o'zi, aks holda tasdiq)";
}

// UP / DOWN / MIXED on the last closed higher-timeframe candle.
string HTFTrendWord(int index, ENUM_TIMEFRAMES tf, string &details) {
   double fast[1], slow[1];
   MqlRates bar[1];
   details="";
   if(HTFHandles[index*2]==INVALID_HANDLE || CopyBuffer(HTFHandles[index*2],0,1,1,fast)!=1 ||
      CopyBuffer(HTFHandles[index*2+1],0,1,1,slow)!=1 || CopyRates(_Symbol,tf,1,1,bar)!=1) return "n/a";
   details="close "+Price(bar[0].close)+", EMA"+(string)FastEMA+" "+Price(fast[0])+", EMA"+(string)SlowEMA+" "+Price(slow[0]);
   return (fast[0]>slow[0] && bar[0].close>fast[0]) ? "UP" : (fast[0]<slow[0] && bar[0].close<fast[0]) ? "DOWN" : "MIXED";
}

string HTFTrend(int index, ENUM_TIMEFRAMES tf) {
   string details, word=HTFTrendWord(index,tf,details);
   return StringSubstr(EnumToString(tf),7)+" "+word+(details!="" ? " ("+details+")" : "");
}

string BiasWord() { return StructureBias>0 ? "bullish" : StructureBias<0 ? "bearish" : "neutral"; }

// Compact context stored in the journal (what the AI saw).
string SignalContext() {
   string d1, d2;
   string h1=HTFTrendWord(0,AIHigherTF1,d1), h2=HTFTrendWord(1,AIHigherTF2,d2);
   return "RSI "+DoubleToString(RSI[1],1)+", "+StringSubstr(EnumToString(AIHigherTF1),7)+" "+h1+", "+
          StringSubstr(EnumToString(AIHigherTF2),7)+" "+h2+", structure "+BiasWord();
}

// Facts only; each AI also receives its own track record and lessons.
string BuildAIPrompt(const LocalSignal &signal) {
   MqlTick tick;
   double spread=SymbolInfoTick(_Symbol,tick) ? (tick.ask-tick.bid)/_Point : 0;
   double risk=MathAbs(signal.entry-signal.sl);
   string p="Symbol: "+_Symbol+" | Signal timeframe: "+EnumToString(TF)+" | Broker time: "+TimeToString(TimeCurrent())+
      "\nProposed: "+(signal.side==1 ? "BUY" : "SELL")+" | Setup: "+signal.setup+
      "\nEntry "+Price(signal.entry)+" | SL "+Price(signal.sl)+" | TP1 (1.5R) "+Price(signal.tp1)+
      " | TP2 (2.25R) "+Price(signal.tp2)+" | TP3 (3R) "+Price(signal.tp3)+
      " | Risk "+DoubleToString(risk/_Point,0)+" points = "+DoubleToString(risk/MathMax(signal.atr,_Point),2)+" ATR"+
      "\nLast closed candle: ATR("+(string)ATRPeriod+") "+Price(ATR[1])+" | EMA"+(string)FastEMA+" "+Price(Fast[1])+
      " | EMA"+(string)SlowEMA+" "+Price(Slow[1])+" | RSI("+(string)RSIPeriod+") "+DoubleToString(RSI[1],1)+
      " | Spread "+DoubleToString(spread,1)+" points"+
      "\nHigher timeframes: "+HTFTrend(0,AIHigherTF1)+"; "+HTFTrend(1,AIHigherTF2)+
      "\nStructure bias: "+BiasWord()+
      " | Last swing high "+(HighPivot.time>0 ? Price(HighPivot.price)+(HighPivot.broken ? " (broken)" : "") : "n/a")+
      " | Last swing low "+(LowPivot.time>0 ? Price(LowPivot.price)+(LowPivot.broken ? " (broken)" : "") : "n/a");
   string blocks="";
   for(int i=0;i<ArraySize(Blocks);i++)
      blocks+="\n- "+(Blocks[i].side==1 ? "Bullish" : "Bearish")+" OB "+Price(Blocks[i].bottom)+"-"+Price(Blocks[i].top)+
              (Blocks[i].touched ? " (touched)" : " (fresh)");
   p+="\nOrder blocks:"+(blocks=="" ? " none" : blocks);
   p+="\nClassic confluence checks (score "+(string)signal.score+", ✅ agrees / ⚠️ against):"+signal.factors;
   p+="\nRule backtest on this chart (same 3-part plan): "+HistoryStatus;
   int count=MathMin(AICandles,ArraySize(Rates)-1);
   p+="\nLast "+(string)count+" closed candles, oldest first (time,open,high,low,close):";
   for(int i=count;i>=1;i--)
      p+="\n"+TimeToString(Rates[i].time)+","+Price(Rates[i].open)+","+Price(Rates[i].high)+","+
         Price(Rates[i].low)+","+Price(Rates[i].close);
   return p;
}

// ---- Lot size and partial-close volumes ---------------------------------------
double VolumeStep() { double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); return step>0 ? step : 0.01; }
double VolumeMin() { return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN); }
string Lots(double volume) {
   int digits=(int)MathMax(0,MathCeil(-MathLog10(VolumeStep())-1e-9));
   return DoubleToString(volume,digits);
}

// Risk-based lot. A small account may use the broker minimum lot if its risk
// stays within MinLotMaxRiskPercent; otherwise no trade.
bool PlanVolume(int side, double entry, double sl, double &volume, double &riskMoney, string &reason) {
   volume=0; riskMoney=0;
   ENUM_ORDER_TYPE type=side==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double loss=0;
   if(!OrderCalcProfit(type,_Symbol,1.0,entry,sl,loss) || loss>=0) { reason="SL riskini hisoblab bo'lmadi"; return false; }
   loss=-loss;
   double step=VolumeStep(), minLot=VolumeMin(), maxLot=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(minLot<=0 || maxLot<minLot) { reason="Broker lot cheklovlari noto'g'ri"; return false; }
   double funds=MathMin(AccountInfoDouble(ACCOUNT_BALANCE),AccountInfoDouble(ACCOUNT_EQUITY));
   if(funds<=0) { reason="Hisobda mablag' yo'q"; return false; }
   volume=MathFloor(MathMin(funds*MaxRiskPercent/100.0/loss,maxLot)/step+1e-9)*step;
   if(volume<minLot-1e-9) {
      double minRiskPct=100.0*loss*minLot/funds;
      if(minRiskPct>MinLotMaxRiskPercent) {
         reason="Hisob kichik: eng kichik lot ("+Lots(minLot)+") riski "+DoubleToString(minRiskPct,1)+
                "% > ruxsat "+DoubleToString(MinLotMaxRiskPercent,1)+"%";
         volume=0; return false;
      }
      volume=minLot;
   }
   volume=NormalizeDouble(volume,8);
   riskMoney=loss*volume;
   return true;
}

// Part to close at a target; 0 when the lot cannot be split (each piece >= min lot).
double PartVolume(double initial, double percent, double current) {
   double step=VolumeStep(), minLot=VolumeMin();
   double part=MathFloor(initial*percent/100.0/step+1e-9)*step;
   if(part<minLot-1e-9 || current-part<minLot-1e-9) return 0;
   return NormalizeDouble(part,8);
}

string SplitText(double volume) {
   double p1=PartVolume(volume,TP1ClosePercent,volume);
   double p2=PartVolume(volume,TP2ClosePercent,volume-p1);
   double rest=volume-p1-p2;
   if(p1<=0) return "Lot "+Lots(volume)+" bo'linmaydi (eng kichik lot): hammasi TP3 gacha"+
                    (MoveSLAfterTP ? ", TP1 da SL Entry ga ko'chadi" : "");
   return "Bo'linish: TP1 "+Lots(p1)+" | TP2 "+(p2>0 ? Lots(p2) : "-")+" | TP3 "+Lots(rest)+" lot";
}

string SignalText(const LocalSignal &signal, bool volumeOk, double volume, double riskMoney, string volumeReason) {
   double risk=MathAbs(signal.entry-signal.sl);
   int pct3=(int)MathRound(100-TP1ClosePercent-TP2ClosePercent);
   string d1, d2;
   string h1=HTFTrendWord(0,AIHigherTF1,d1), h2=HTFTrendWord(1,AIHigherTF2,d2);
   string text="📊 SIGNAL | "+_Symbol+" "+StringSubstr(EnumToString(TF),7)+" | "+(signal.side==1 ? "🟢 BUY" : "🔴 SELL")+
      "\nSetup: "+signal.setup+"\nSham yopildi (broker vaqti): "+TimeToString(signal.time)+
      (signal.zoneTop>0 ? "\n🧭 Zona: "+Price(signal.zoneBottom)+" – "+Price(signal.zoneTop)+
                          " (SL zona chegarasidan "+DoubleToString(SLBufferATR,2)+" ATR past)" : "")+
      "\n━━━━━━━━━━━━━━"+
      "\n▶️ Kirish: "+Price(signal.entry)+" (bozor narxida)"+
      "\n🛑 Stop Loss: "+Price(signal.sl)+" ("+Distance(risk)+")"+
      "\n🎯 TP1: "+Price(signal.tp1)+" ("+DoubleToString(TP1_R,2)+"R, +"+Distance(risk*TP1_R)+") → "+
         DoubleToString(TP1ClosePercent,0)+"% yopiladi"+(MoveSLAfterTP ? ", SL → Entry (zararsiz)" : "")+
      "\n🎯 TP2: "+Price(signal.tp2)+" ("+DoubleToString(TP2_R,2)+"R, +"+Distance(risk*TP2_R)+") → "+
         DoubleToString(TP2ClosePercent,0)+"% yopiladi"+(MoveSLAfterTP ? ", SL → TP1" : "")+
      "\n🏁 TP3 asosiy: "+Price(signal.tp3)+" ("+DoubleToString(TP3_R,2)+"R, +"+Distance(risk*TP3_R)+") → qolgan "+
         (string)pct3+"% (brokerga qo'yiladi)"+
      "\n━━━━━━━━━━━━━━";
   if(volumeOk) {
      double balance=AccountInfoDouble(ACCOUNT_BALANCE);
      bool split=PartVolume(volume,TP1ClosePercent,volume)>0;
      text+="\n💼 Lot: "+Lots(volume)+" | Risk: -"+Money(riskMoney)+" ("+DoubleToString(100.0*riskMoney/MathMax(balance,0.01),2)+"%)"+
            "\n💰 Hammasi TP gacha: +"+Money(riskMoney*(split ? PlanFullR() : TP3_R))+
            "\n"+SplitText(volume);
   } else text+="\n⚠️ Order ochib bo'lmaydi: "+volumeReason;
   text+="\n🧩 TASDIQLAR (konfluens "+(string)signal.score+"):"+signal.factors;
   text+="\n📈 Trend: "+StringSubstr(EnumToString(AIHigherTF1),7)+" "+h1+" | "+StringSubstr(EnumToString(AIHigherTF2),7)+" "+h2+
         " | RSI "+DoubleToString(RSI[1],1)+" | struktura "+BiasWord();
   return text;
}

#include "AZT_SignalImage.mqh"

void Notify(const string key, const string text, const string markup="") {
   Print("AZT: ",text);
   AZTTelegramQueue(key,AZTTrimTo(text,4000),300,markup);
}

void Panel() {
   MqlTick tick;
   string spread="waiting";
   if(SymbolInfoTick(_Symbol,tick) && tick.ask>0 && tick.bid>0)
      spread=DoubleToString((tick.ask-tick.bid)/_Point,1)+" points";
   string connection=TerminalInfoInteger(TERMINAL_CONNECTED) ? "connected" : "DISCONNECTED";
   if(MQLInfoInteger(MQL_TESTER)) connection="Strategy Tester";
   Comment("AI Zone Trader 4 | ",_Symbol," ",EnumToString(TF)," | ",connection,
      "\nRejim: ",ModeName(),
      "\nRisk: ",DoubleToString(MaxRiskPercent,1),"% | TP: ",DoubleToString(TP1ClosePercent,0),"% @",DoubleToString(TP1_R,2),
      "R, ",DoubleToString(TP2ClosePercent,0),"% @",DoubleToString(TP2_R,2),"R, rest @",DoubleToString(TP3_R,2),"R",
      "\nAI: ",AZTAIStatus(),(AITestStatus!="" ? "\nAI test: "+AITestStatus : ""),
      "\n",JournalScore(AZT_AI_CLAUDE),
      Pending.active ? "\nTELEGRAM TASDIG'I KUTILMOQDA: "+Pending.id : "",
      "\n",Status,"\nLast closed candle: ",TimeToString(LastClosedBar),
      "\nSpread: ",spread," | Order limit: ",DoubleToString(MaxSpreadPoints,1),
      "\nLast signal: ",LastSignal,
      "\nStructure: ",StructureStatus,
      "\nHistory: ",HistoryStatus,
      "\nTelegram: ",AZTTelegramStatus(),
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
   if(-net>=balance*MaxDailyLossPercent/100.0) { reason="Kunlik zarar limiti"; return false; }
   if(streak>=MaxConsecutiveLosses) { reason="Ketma-ket zarar limiti"; return false; }
   return true;
}

string PosKey(ulong ticket) { return "AZTP."+PosScope+"."+(string)ticket; }

bool AZTPositionSlotAvailable(int positions,int orders,int limit,bool hedging,bool sameSymbol) {
   return positions+orders<limit && (hedging || !sameSymbol);
}
bool AutoOrder(const LocalSignal &signal, string &reason) {
   // Serialize this EA's entries across charts before checking the account cap.
   string file="AZT_order_"+(string)AccountInfoInteger(ACCOUNT_LOGIN)+".lock";
   int lock=FileOpen(file,FILE_READ|FILE_WRITE|FILE_BIN);
   if(lock==INVALID_HANDLE) { reason="Boshqa chart order ochmoqda; bu signal o'tkazildi"; return false; }
   bool ok=AutoOrderLocked(signal,reason);
   FileClose(lock);
   return ok;
}
bool AutoOrderLocked(const LocalSignal &signal, string &reason) {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) ||
      !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) {
      reason="MT5 da Algo Trading tugmasi yoki EA savdo ruxsati O'CHIQ"; return false;
   }
   if(!AZTPositionSlotAvailable(PositionsTotal(),OrdersTotal(),MaxOpenPositions,true,false)) {
      reason="Ochiq pozitsiya/order limiti ("+(string)MaxOpenPositions+")"; return false;
   }
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE)!=ACCOUNT_MARGIN_MODE_RETAIL_HEDGING && PositionSelect(_Symbol)) {
      reason="Bu symbol ochiq: alohida parallel pozitsiyalar uchun hedging hisob kerak"; return false;
   }
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || tick.bid<=0) { reason="Narx yo'q"; return false; }
   if((tick.ask-tick.bid)/_Point>MaxSpreadPoints) { reason="Spread katta ("+DoubleToString((tick.ask-tick.bid)/_Point,0)+" pt)"; return false; }
   double balance=AccountInfoDouble(ACCOUNT_BALANCE), equity=AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance<=0 || equity<=0) { reason="Hisobda mablag' yo'q"; return false; }
   if((balance-equity)/balance*100.0>=MaxDrawdownPercent) { reason="Drawdown limiti"; return false; }
   if(!DailyRiskSafe(reason)) return false;
   double entry=signal.side==1 ? tick.ask : tick.bid;
   if(MathAbs(entry-signal.entry)>signal.atr*MaxEntryDriftATR) { reason="Narx signaldan juda uzoqlashdi"; return false; }
   double distance=signal.side*(entry-signal.sl);
   double minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double marketClose=signal.side==1 ? tick.bid : tick.ask;
   if(distance<=0 || signal.side*(marketClose-signal.sl)<=minStop) { reason="SL broker cheklovini buzadi"; return false; }
   // Broker TP = TP3 from the real entry; TP1/TP2 partial closes are managed by the EA.
   double tp=TickPrice(entry+signal.side*distance*TP3_R,signal.side);
   if(tp<=0 || signal.side*(tp-marketClose)<=minStop) { reason="TP broker cheklovini buzadi"; return false; }
   ENUM_ORDER_TYPE type=signal.side==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double volume, riskMoney;
   if(!PlanVolume(signal.side,entry,signal.sl,volume,riskMoney,reason)) return false;
   double margin=0;
   if(!OrderCalcMargin(type,_Symbol,volume,entry,margin) || margin>AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
      reason="Erkin margin yetarli emas"; return false;
   }
   Trade.SetTypeFillingBySymbol(_Symbol);
   string comment="AZT-"+(string)(long)signal.time;
   bool sent=signal.side==1 ? Trade.Buy(volume,_Symbol,entry,signal.sl,tp,comment)
                           : Trade.Sell(volume,_Symbol,entry,signal.sl,tp,comment);
   uint code=Trade.ResultRetcode();
   if(!sent || (code!=TRADE_RETCODE_DONE && code!=TRADE_RETCODE_DONE_PARTIAL && code!=TRADE_RETCODE_PLACED)) {
      reason="Broker rad etdi: "+(string)code+" "+Trade.ResultRetcodeDescription(); return false;
   }
   // Remember the original risk so TP1/TP2 management survives EA restarts.
   double open=entry, filled=volume;
   ulong ticket=0, positionId=0;
   if(Trade.ResultDeal()>0 && HistoryDealSelect(Trade.ResultDeal()))
      positionId=(ulong)HistoryDealGetInteger(Trade.ResultDeal(),DEAL_POSITION_ID);
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(t>0 && (t==Trade.ResultOrder() || (positionId>0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER)==positionId)) && PositionGetString(POSITION_SYMBOL)==_Symbol && PositionGetInteger(POSITION_MAGIC)==(long)MagicNumber) {
         ticket=t; open=PositionGetDouble(POSITION_PRICE_OPEN); filled=PositionGetDouble(POSITION_VOLUME); break;
      }
   }
   double risk=MathAbs(open-signal.sl);
   if(ticket>0) {
      GlobalVariableSet(PosKey(ticket)+".r",risk);
      GlobalVariableSet(PosKey(ticket)+".v",filled);
      GlobalVariableSet(PosKey(ticket)+".s",0);
      GlobalVariableSet(PosKey(ticket)+".m",riskMoney);
      GlobalVariablesFlush();
   }
   reason="Order ochildi #"+(string)ticket+" | "+(signal.side==1 ? "BUY " : "SELL ")+Lots(filled)+" lot @ "+Price(open)+
      "\nSL "+Price(signal.sl)+" | TP1 "+Price(open+signal.side*risk*TP1_R)+" | TP2 "+Price(open+signal.side*risk*TP2_R)+
      " | TP3 "+Price(tp)+"\nRisk: -"+Money(riskMoney)+"\n"+SplitText(filled);
   return true;
}

// TP1/TP2 partial closes and stop moves for this EA's positions on this symbol.
void ManagePositions() {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.bid<=0) return;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=_Symbol ||
         PositionGetInteger(POSITION_MAGIC)!=(long)MagicNumber) continue;
      string key=PosKey(ticket);
      if(!GlobalVariableCheck(key+".r")) continue;
      int stage=(int)GlobalVariableGet(key+".s");
      double r=GlobalVariableGet(key+".r"), initial=GlobalVariableGet(key+".v");
      if(stage>=2 || r<=0) continue;
      int side=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY ? 1 : -1;
      double open=PositionGetDouble(POSITION_PRICE_OPEN), volume=PositionGetDouble(POSITION_VOLUME);
      double sl=PositionGetDouble(POSITION_SL), tp=PositionGetDouble(POSITION_TP);
      double price=side==1 ? tick.bid : tick.ask;
      double target=open+side*r*(stage==0 ? TP1_R : TP2_R);
      if(side*(price-target)<0) continue;
      GlobalVariableSet(key+".s",stage+1); // once per stage, even if the broker refuses
      GlobalVariablesFlush();
      string message="🎯 TP"+(string)(stage+1)+" | "+_Symbol+" #"+(string)ticket+" narx "+Price(price);
      double part=PartVolume(initial,stage==0 ? TP1ClosePercent : TP2ClosePercent,volume);
      if(part>0) {
         if(Trade.PositionClosePartial(ticket,part)) message+="\n✅ "+Lots(part)+" lot yopildi (foyda olindi)";
         else message+="\n⚠️ Qisman yopilmadi: "+Trade.ResultRetcodeDescription();
      } else message+="\nℹ️ Lot kichik, qism yopilmadi";
      if(MoveSLAfterTP) {
         double newSL=TickPrice(stage==0 ? open : open+side*r*TP1_R,side);
         double minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
         if(side*(newSL-sl)>0 && side*(price-newSL)>minStop && PositionSelectByTicket(ticket)) {
            if(Trade.PositionModify(ticket,newSL,tp))
               message+="\n🛡 SL → "+Price(newSL)+(stage==0 ? " (Entry, endi zarar yo'q)" : " (TP1, foyda himoyalandi)");
            else message+="\n⚠️ SL ko'chmadi: "+Trade.ResultRetcodeDescription();
         }
      }
      Notify("mg|"+(string)ticket+"|"+(string)stage,message);
   }
}

// Reports the real money result once a managed position is fully closed.
void ReportClosedPositions() {
   string prefix="AZTP."+PosScope+".";
   string names[];
   for(int i=GlobalVariablesTotal()-1;i>=0;i--) {
      string name=GlobalVariableName(i);
      if(StringFind(name,prefix)==0 && StringSubstr(name,StringLen(name)-2)==".r") {
         int n=ArraySize(names); ArrayResize(names,n+1); names[n]=StringSubstr(name,0,StringLen(name)-2);
      }
   }
   for(int i=0;i<ArraySize(names);i++) {
      ulong ticket=(ulong)StringToInteger(StringSubstr(names[i],StringLen(prefix)));
      if(ticket==0 || PositionSelectByTicket(ticket)) continue;
      if(!HistorySelectByPosition(ticket)) continue;
      double net=0;
      for(int d=0;d<HistoryDealsTotal();d++) {
         ulong deal=HistoryDealGetTicket(d);
         net+=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+
              HistoryDealGetDouble(deal,DEAL_COMMISSION)+HistoryDealGetDouble(deal,DEAL_FEE);
      }
      double riskMoney=GlobalVariableGet(names[i]+".m");
      int stage=(int)GlobalVariableGet(names[i]+".s");
      Notify("cl|"+(string)ticket,(net>=0 ? "💰" : "🔻")+" SAVDO YOPILDI | "+_Symbol+" #"+(string)ticket+
         "\nNatija: "+(net>=0 ? "+" : "")+Money(net)+(riskMoney>0 ? " ("+DoubleToString(net/riskMoney,2)+"R)" : "")+
         " | olingan TP: "+(string)stage+
         "\nBalans: "+Money(AccountInfoDouble(ACCOUNT_BALANCE)));
      GlobalVariableDel(names[i]+".r"); GlobalVariableDel(names[i]+".v");
      GlobalVariableDel(names[i]+".s"); GlobalVariableDel(names[i]+".m");
   }
}

// Every live signal is appended to MQL5/Files/AZT_signals.csv, so other tools (Ali) can read it.
void ExportSignal(const LocalSignal &signal) {
   int h=FileOpen("AZT_signals.csv",FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ);
   if(h==INVALID_HANDLE) { Print("AZT: signal CSV ochilmadi: ",GetLastError()); return; }
   if(FileSize(h)==0) FileWriteString(h,"time,symbol,timeframe,side,setup,entry,sl,tp1,tp2,tp3,zone_low,zone_high,score,atr\r\n");
   FileSeek(h,0,SEEK_END);
   FileWriteString(h,TimeToString(signal.time,TIME_DATE|TIME_MINUTES)+","+_Symbol+","+EnumToString(TF)+","+
      (signal.side==1 ? "BUY" : "SELL")+","+signal.setup+","+Price(signal.entry)+","+Price(signal.sl)+","+
      Price(signal.tp1)+","+Price(signal.tp2)+","+Price(signal.tp3)+","+Price(signal.zoneBottom)+","+
      Price(signal.zoneTop)+","+(string)signal.score+","+DoubleToString(signal.atr,_Digits)+"\r\n");
   FileClose(h);
}

void Scan() {
   if(!Ready) {
      int count=RequiredBars()+HistoryBars;
      int available=Bars(_Symbol,TF);
      if(available<RequiredBars()) {
         CopyRates(_Symbol,TF,0,RequiredBars(),Rates);
         Status="Waiting for price history"; Panel(); return;
      }
      count=MathMin(count,available);
      if(!LoadData(count)) { Status="Waiting for indicator data"; Panel(); return; }
      RebuildStructure();
      RunHistoricalAnalysis();
      ResolveJournal();
      LastClosedBar=Rates[1].time;
      Ready=true;
      Status="Ready: waiting for the next candle close";
      Print("AZT ready: ",_Symbol," ",EnumToString(TF),"; historical signals=",HistoricalSignals,
            "; mode=",ModeName(),". Historical signals never trigger orders/alerts.");
      Panel(); return;
   }
   datetime closed=iTime(_Symbol,TF,1);
   if(closed<=0 || closed==LastClosedBar) { Panel(); return; }
   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_CONNECTED)) {
      Status="Waiting: broker disconnected"; Panel(); return;
   }
   int count=MathMin(Bars(_Symbol,TF),RequiredBars()+HistoryBars);
   if(count<RequiredBars() || !LoadData(count)) { Status="Waiting for indicator data; will retry"; Panel(); return; }
   RebuildStructure();
   // Only mark processed after all data is ready; shared OnTick/OnTimer guard.
   LastClosedBar=Rates[1].time;
   RunHistoricalAnalysis(false);
   ResolveJournal();
   if(!MQLInfoInteger(MQL_TESTER) && TimeCurrent()-Rates[0].time>MaxSignalDelaySeconds) {
      Status="Late candle skipped: waiting for a fresh close"; Panel(); return;
   }
   LocalSignal signal; string reason;
   if(!EvaluateSignal(1,signal,reason)) { Status=reason; Print("AZT: ",Status); Panel(); return; }
   if(CoolingDown(1)) { Status="Waiting: signal cooldown"; Panel(); return; }
   LastSignalBar=signal.time;
   DrawSignal(signal,false);
   Status=(signal.side==1 ? "BUY" : "SELL")+string(" signal: ")+signal.setup;
   string message="AZT "+_Symbol+" "+EnumToString(TF)+" "+Status+" | Entry "+Price(signal.entry)+
      " SL "+Price(signal.sl)+" TP1 "+Price(signal.tp1)+" TP2 "+Price(signal.tp2)+" TP3 "+Price(signal.tp3);
   Print(message);
   if(!MQLInfoInteger(MQL_TESTER)) {
      ExportSignal(signal);
      if(PopupAlerts) Alert(message);
      if(PushNotifications && !SendNotification(message)) Print("Push notification failed: ",GetLastError());
   }
   HandleSignal(signal);
   Panel(); ChartRedraw();
}

// Scores earlier signals on new closed candles and reports each AI's accuracy.
void ResolveJournal() {
   if(MQLInfoInteger(MQL_TESTER)) return;
   int resolved[];
   if(JournalResolve(resolved)==0) return;
   for(int i=0;i<ArraySize(resolved);i++)
      if(Journal[resolved[i]].outcome==1 || Journal[resolved[i]].outcome==-1)
         Notify("jr|"+Journal[resolved[i]].id,JournalResultText(resolved[i]));
}

// AI review, then: no trade / trade alone / ask for the Telegram button.
void HandleSignal(const LocalSignal &signal) {
   string id=AZTTelegramHash(_Symbol+"|"+EnumToString(TF)+"|"+(string)(long)signal.time+"|"+(string)MagicNumber);
   string key=_Symbol+"|"+EnumToString(TF)+"|"+(string)(long)signal.time;
   string reason, volumeReason;
   double volume=0, riskMoney=0;
   bool volumeOk=PlanVolume(signal.side,signal.entry,signal.sl,volume,riskMoney,volumeReason);
   if(MQLInfoInteger(MQL_TESTER)) {
      // No Telegram/AI in the tester: modes 1-2 trade the rules so they can be measured.
      TradeStatus="Signals only: orders are OFF";
      if(TradeMode!=AZT_SIGNALS_ONLY) TradeStatus=(AutoOrder(signal,reason) ? "" : "Order skipped: ")+reason;
      return;
   }
   QueueSignalImage(signal,key);
   string text=SignalText(signal,volumeOk,volume,riskMoney,volumeReason);
   AZTAIVerdict verdicts[AZT_AI_COUNT];
   for(int p=0;p<AZT_AI_COUNT;p++) ZeroMemory(verdicts[p]);
   int providers=AZTAIProviders(), approvals=0, rejections=0, minConfidence=100;
   string trustNote="";
   if(InpAIEnabled && providers>0) {
      Status="AI tahlil qilmoqda..."; Panel();
      string prompt=BuildAIPrompt(signal);
      text+="\n\n🤖 AI TAHLIL:";
      for(int p=0;p<AZT_AI_COUNT;p++) {
         if(!AZTAIHasKey(p)) continue;
         AZTAIReview(p,prompt+JournalMemory(p),verdicts[p]);
         text+="\n"+AZTAIVerdictText(AZTAIName(p),verdicts[p]);
         if(!verdicts[p].ok) continue;
         if(verdicts[p].decision==1) {
            approvals++; minConfidence=MathMin(minConfidence,verdicts[p].confidence);
            int samples; double precision=JournalApprovePrecision(p,samples);
            if(samples>=8 && precision<InpAIMinPrecision)
               trustNote+="\n⚠️ "+AZTAIName(p)+" so'nggi APPROVE aniqligi "+DoubleToString(precision,0)+"% ("+
                          (string)samples+" ta): o'zi savdo ocholmaydi";
         } else rejections++;
      }
      text+=trustNote;
   } else text+="\n\n🤖 AI: o'chiq (AZT_Config.ini da API kalit yo'q)";
   bool aiAgrees=providers>0 && approvals==providers && minConfidence>=InpAIAutoConfidence && trustNote=="";
   bool aiRejects=rejections>0 && approvals==0;
   string context=SignalContext();
   Status=(signal.side==1 ? "BUY" : "SELL")+string(" signal: ")+signal.setup+
          " | AI approve="+(string)approvals+" reject="+(string)rejections;

   if(TradeMode==AZT_SIGNALS_ONLY) {
      TradeStatus="Faqat signal rejimi";
      JournalAdd(id,signal,context,verdicts,"SIGNAL_ONLY");
      Notify(key,text+"\n\nℹ️ Faqat signal rejimi: savdo ochilmaydi.");
      return;
   }
   if(aiRejects && SkipWhenAIRejects) {
      TradeStatus="AI rad etdi: savdo yo'q";
      JournalAdd(id,signal,context,verdicts,"AI_REJECT");
      Notify(key,text+"\n\n⛔ AI rad etdi: savdoga kirilmaydi. Natijasi baribir kuzatiladi va AI'ga ko'rsatiladi.");
      return;
   }
   if(!volumeOk) {
      TradeStatus="No trade: "+volumeReason;
      JournalAdd(id,signal,context,verdicts,"NO_VOLUME");
      Notify(key,text+"\n\n⚠️ Savdo ochilmaydi: "+volumeReason);
      return;
   }
   if(TradeMode==AZT_AI_HYBRID && aiAgrees) {
      bool ok=AutoOrder(signal,reason);
      TradeStatus=(ok ? "AI auto: " : "AI auto skipped: ")+reason;
      JournalAdd(id,signal,context,verdicts,ok ? "AUTO" : "AUTO_FAILED");
      Notify(key,text+"\n\n"+(ok ? "✅ Claude tasdiqladi → " : "⚠️ AI tasdiqladi, lekin order ochilmadi: ")+reason);
      return;
   }
   if(!AZTTelegramReady()) {
      TradeStatus="Tasdiq kerak, lekin Telegram ulanmagan: savdo yo'q";
      JournalAdd(id,signal,context,verdicts,"NO_TELEGRAM");
      return;
   }
   if(Pending.active) {
      JournalSetAction(Pending.id,"SUPERSEDED");
      Notify("sup|"+Pending.id,"Avvalgi tasdiq so'rovi yangi signal bilan almashtirildi: "+Pending.id);
   }
   Pending.active=true; Pending.id=id; Pending.signal=signal;
   Pending.expires=TimeLocal()+ApprovalTimeoutMinutes*60;
   TradeStatus="Telegram tasdig'i kutilmoqda ("+(string)ApprovalTimeoutMinutes+" daqiqa)";
   JournalAdd(id,signal,context,verdicts,"WAITING");
   Notify(key,text+"\n\n❓ SAVDOGA KIRAMIZMI? "+(string)ApprovalTimeoutMinutes+" daqiqa ichida tugmani bosing."+
      "\nNarx signaldan "+DoubleToString(MaxEntryDriftATR,2)+" ATR dan ko'p qochsa, order ochilmaydi.",AZTApprovalMarkup(id));
}

// Called from OnTimer: executes or drops the trade once you press a button.
void ProcessPending() {
   if(!Pending.active) return;
   int decision=AZTDecision(Pending.id);
   if(decision==0) { AZTTelegramPollDecisions(); decision=AZTDecision(Pending.id); }
   if(decision==0) {
      if(TimeLocal()<Pending.expires) return;
      Pending.active=false;
      TradeStatus="Tasdiq muddati tugadi: savdo yo'q";
      JournalSetAction(Pending.id,"EXPIRED");
      Notify("exp|"+Pending.id,"⌛ "+_Symbol+" "+StringSubstr(EnumToString(TF),7)+": tasdiq muddati tugadi, savdo ochilmadi.");
      return;
   }
   Pending.active=false;
   if(decision<0) {
      TradeStatus="Siz bekor qildingiz";
      JournalSetAction(Pending.id,"USER_REJECT");
      Notify("res|"+Pending.id,"❌ "+_Symbol+": siz bekor qildingiz, savdo ochilmadi.");
      return;
   }
   string reason;
   bool ok=AutoOrder(Pending.signal,reason);
   TradeStatus=(ok ? "Tasdiqlandi: " : "Tasdiqlandi, lekin ochilmadi: ")+reason;
   JournalSetAction(Pending.id,ok ? "APPROVED" : "APPROVED_FAILED");
   Notify("res|"+Pending.id,(ok ? "✅ "+_Symbol+": tasdiqingiz bilan order ochildi.\n" :
                                  "⚠️ "+_Symbol+": tasdiqlandi, lekin order ochilmadi.\n")+reason);
}

// Telegram test: a sample signal from the current price with working buttons.
// Pressing a button only gets a reply; no order is ever placed.
string TestId="";
datetime TestExpires=0, TestSentAt=0;

void RequestTelegramTest() {
   if(!AZTTelegramReady()) { TradeStatus="Telegram ulanmagan: "+AZTTelegramStatus(); return; }
   if(TimeLocal()-TestSentAt<30) return;
   MqlTick tick;
   double atr=ArraySize(ATR)>1 ? ATR[1] : 0;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask<=0 || atr<=0) { TradeStatus="Test: narx/ATR hali tayyor emas"; return; }
   LocalSignal sample; ZeroMemory(sample);
   sample.side=1; sample.time=TimeCurrent(); sample.atr=atr; sample.setup="TEST (namuna)";
   sample.entry=TickPrice(tick.ask); sample.sl=TickPrice(sample.entry-StopATR*atr,-1);
   double risk=sample.entry-sample.sl;
   sample.tp1=TickPrice(sample.entry+risk*TP1_R,1); sample.tp2=TickPrice(sample.entry+risk*TP2_R,1);
   sample.tp3=TickPrice(sample.entry+risk*TP3_R,1);
   sample.factors="\n• Bu namuna: haqiqiy signalda MACD, MA200, FVG, S/R, Fibonacci va patternlar shu yerda bo'ladi";
   double volume=0, riskMoney=0; string reason;
   bool ok=PlanVolume(1,sample.entry,sample.sl,volume,riskMoney,reason);
   TestId="T"+StringSubstr(AZTTelegramHash(_Symbol+(string)(long)TimeLocal()),0,12);
   TestExpires=TimeLocal()+15*60; TestSentAt=TimeLocal();
   Notify("test|"+TestId,"🧪 TELEGRAM TEST — savdo OCHILMAYDI\n"+SignalText(sample,ok,volume,riskMoney,reason)+
      "\n\nTugmalarni sinang: bosganingizga EA javob beradi.",AZTApprovalMarkup(TestId));
   TradeStatus="Telegram test yuborildi: tugmani bosing";
}

void ProcessTelegramTest() {
   if(TestId=="") return;
   int decision=AZTDecision(TestId);
   if(decision==0) { AZTTelegramPollDecisions(); decision=AZTDecision(TestId); }
   if(decision==0) { if(TimeLocal()>=TestExpires) TestId=""; return; }
   Notify("testres|"+TestId,decision>0 ? "✅ TEST: siz TASDIQLADINGIZ. Haqiqiy signalda EA hozir savdoga kirardi."
                                       : "❌ TEST: siz RAD ETDINGIZ. Haqiqiy signalda savdo ochilmasdi.");
   TradeStatus=decision>0 ? "Telegram test: tasdiqlash tugmasi ishlaydi" : "Telegram test: rad etish tugmasi ishlaydi";
   TestId="";
}

void RunAITest() {
   AITestStatus="tekshirilmoqda...";
   Panel();
   AZTAIInit();
   string claude=AZTAIPing(AZT_AI_CLAUDE);
   AITestStatus=claude;
   Notify("aitest|"+(string)(long)TimeLocal(),"🧪 AI TEST | "+_Symbol+"\n"+claude+
      "\nBu savdo signali emas.");
}

void Button(string name, int y, string text) {
   ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_RIGHT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,180);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,165);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,26);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
}

int OnInit() {
   if(FastEMA<2 || SlowEMA<=FastEMA || SlowEMA>1000 || RSIPeriod<2 || RSIPeriod>1000 ||
      ATRPeriod<2 || ATRPeriod>1000 || SwingLookback<1 || SwingLookback>500 ||
      SLBufferATR<0 || HistoryBars<0 || HistoryBars>5000 || HistoryMaxHoldingBars<1 || HistoryMaxHoldingBars>2000 ||
      HistoryRoundTripCostPoints<0 || CooldownBars<0 || MaxSignalDelaySeconds<1 || StopATR<=0 ||
      StructureLookback<50 || StructureLookback>2000 || PivotBars<1 || PivotBars>20 ||
      OBSearchBars<1 || OBSearchBars>100 || OBImpulseATR<=0 || MaxOrderBlocks<1 || MaxOrderBlocks>30 ||
      OBMaxAgeBars<1 || OBMaxAgeBars>2000 || StructureExtendBars<1 || StructureExtendBars>100 ||
      TrendlineToleranceATR<=0 || TrendlineToleranceATR>3 ||
      TP1_R<=0 || TP2_R<=TP1_R || TP3_R<=TP2_R ||
      TP1ClosePercent<=0 || TP2ClosePercent<0 || TP1ClosePercent+TP2ClosePercent>=100 ||
      RSIBuyMin<0 || RSIBuyMax>100 || RSIBuyMin>=RSIBuyMax ||
      RSISellMin<0 || RSISellMax>100 || RSISellMin>=RSISellMax ||
      (!EnableCrossSignals && !EnablePullbackSignals && !EnableStructureBreakSignals &&
       !EnableOrderBlockSignals && !EnableTrendlineSignals) || MaxRiskPercent<=0 || MaxRiskPercent>100 ||
      MinLotMaxRiskPercent<MaxRiskPercent || MaxDailyLossPercent<=0 || MaxDrawdownPercent<=0 || MaxConsecutiveLosses<1 ||
      MaxOpenPositions<1 || MaxSpreadPoints<=0 || MaxEntryDriftATR<=0 || SlippagePoints<0 ||
      ApprovalTimeoutMinutes<1 || ApprovalTimeoutMinutes>1440 || AICandles<5 || AICandles>200 ||
      MACDFast<2 || MACDSlow<=MACDFast || MACDSignalPeriod<2 || TrendMAPeriod<10 || TrendMAPeriod>1000 ||
      FVGLookback<3 || FVGLookback>500 || FVGMinATR<0 || SNRLookback<20 || SNRLookback>2000 ||
      SNRZoneATR<=0 || SNRMinTouches<2 || MinConfluence<-10 || MinConfluence>10) {
      Print("AZT: Invalid input parameters"); return INIT_PARAMETERS_INCORRECT;
   }
   TF=SignalTimeframe==PERIOD_CURRENT ? (ENUM_TIMEFRAMES)_Period : SignalTimeframe;
   Prefix="AZT_LOCAL_"+(string)MagicNumber+"_";
   PosScope=StringSubstr(AZTTelegramHash(_Symbol+"|"+(string)MagicNumber),0,8);
   ArraySetAsSeries(Rates,true); ArraySetAsSeries(Fast,true); ArraySetAsSeries(Slow,true);
   ArraySetAsSeries(RSI,true); ArraySetAsSeries(ATR,true);
   ArraySetAsSeries(MACDMain,true); ArraySetAsSeries(MACDSignal,true); ArraySetAsSeries(TrendMA,true);
   FastHandle=iMA(_Symbol,TF,FastEMA,0,MODE_EMA,PRICE_CLOSE);
   SlowHandle=iMA(_Symbol,TF,SlowEMA,0,MODE_EMA,PRICE_CLOSE);
   RSIHandle=iRSI(_Symbol,TF,RSIPeriod,PRICE_CLOSE); ATRHandle=iATR(_Symbol,TF,ATRPeriod);
   MACDHandle=iMACD(_Symbol,TF,MACDFast,MACDSlow,MACDSignalPeriod,PRICE_CLOSE);
   TrendMAHandle=iMA(_Symbol,TF,TrendMAPeriod,0,MODE_SMA,PRICE_CLOSE);
   if(FastHandle==INVALID_HANDLE || SlowHandle==INVALID_HANDLE || RSIHandle==INVALID_HANDLE || ATRHandle==INVALID_HANDLE ||
      MACDHandle==INVALID_HANDLE || TrendMAHandle==INVALID_HANDLE) {
      Print("AZT: Cannot create indicators: ",GetLastError()); return INIT_FAILED;
   }
   Trade.SetExpertMagicNumber(MagicNumber); Trade.SetDeviationInPoints(SlippagePoints);
   Trade.SetAsyncMode(false);
   AZTTelegramInit();
   AZTAIInit();
   if(!MQLInfoInteger(MQL_TESTER)) {
      ENUM_TIMEFRAMES htf[2]={AIHigherTF1,AIHigherTF2};
      for(int i=0;i<2;i++) {
         HTFHandles[i*2]=iMA(_Symbol,htf[i],FastEMA,0,MODE_EMA,PRICE_CLOSE);
         HTFHandles[i*2+1]=iMA(_Symbol,htf[i],SlowEMA,0,MODE_EMA,PRICE_CLOSE);
      }
      JournalLoad();
      Button(Prefix+"TELEGRAM_TEST",25,"Telegram TEST (tugmali)");
      Button(Prefix+"AI_TEST",55,"AI TEST (Claude)");
      if(TradeMode!=AZT_SIGNALS_ONLY && !AZTTelegramReady())
         Print("AZT: WARNING - Telegram is not ready, so trades needing your approval cannot open.");
   }
   if(!EventSetTimer(2)) { Print("AZT: Cannot start timer"); return INIT_FAILED; }
   TradeStatus=TradeMode==AZT_SIGNALS_ONLY ? "Faqat signal: savdo o'chiq" : "Savdo: AI kelishuvi yoki sizning tasdig'ingiz bilan";
   Panel();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   if(FastHandle!=INVALID_HANDLE) IndicatorRelease(FastHandle);
   if(SlowHandle!=INVALID_HANDLE) IndicatorRelease(SlowHandle);
   if(RSIHandle!=INVALID_HANDLE) IndicatorRelease(RSIHandle);
   if(ATRHandle!=INVALID_HANDLE) IndicatorRelease(ATRHandle);
   if(MACDHandle!=INVALID_HANDLE) IndicatorRelease(MACDHandle);
   if(TrendMAHandle!=INVALID_HANDLE) IndicatorRelease(TrendMAHandle);
   for(int i=0;i<4;i++) if(HTFHandles[i]!=INVALID_HANDLE) { IndicatorRelease(HTFHandles[i]); HTFHandles[i]=INVALID_HANDLE; }
   if(Prefix!="") ObjectsDeleteAll(0,Prefix);
   Comment("");
}

void OnTimer() {
   Scan();
   ProcessPending();
   ProcessTelegramTest();
   ManagePositions();
   ReportClosedPositions();
   if(Ready && !Pending.active) JournalReflectOne();
   AZTTelegramPump();
   Panel();
}

void OnTick() { Scan(); ManagePositions(); }

void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam) {
   if(id!=CHARTEVENT_OBJECT_CLICK) return;
   if(sparam==Prefix+"TELEGRAM_TEST") {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      RequestTelegramTest();
      Panel();
   }
   if(sparam==Prefix+"AI_TEST") {
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
      RunAITest();
      Panel();
   }
}
