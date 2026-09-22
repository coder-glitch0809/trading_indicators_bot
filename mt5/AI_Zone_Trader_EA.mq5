//+------------------------------------------------------------------+
//| AI Zone Trader EA: Telegram-confirmed pending orders only.      |
//| Safer, multi-strategy, always-on market monitor.                |
//+------------------------------------------------------------------+
#property strict
#property version   "0.2"
#include <Trade/Trade.mqh>

input string ServerUrl = "https://server-xi-rose-97.vercel.app/";
input string ApiKey = "mt5_mql5_secret_key";
input string SymbolOverride = "";              // e.g. XAUUSD.a; blank = current chart
input double MaxRiskPercent = 0.50;
input int PollSeconds = 10;
input ulong MagicNumber = 260916;
input int SlippagePoints = 30;
input int TrendLookback = 40;
input int ConfirmationBars = 2;
input double MaxSpreadPoints = 18.0;
input double MaxDrawdownPercent = 10.0;
input int MaxOpenPositions = 1;
input bool EnableTrendlineScan = true;
input bool EnableFVGScan = true;
input bool EnableScalp = true;
input bool EnableSwing = true;
input bool EnableSniper = true;
input bool AutoDrawStructure = true;

CTrade trade;

string ActiveSymbol() { return SymbolOverride == "" ? _Symbol : SymbolOverride; }

string NormalizeStrategy(string str) {
   string s = StringUpper(str);
   if(s=="SCALP" || s=="SCALPING") return "SCALP";
   if(s=="SWING") return "SWING";
   if(s=="SNIPER") return "SNIPER";
   if(s=="FVG") return "FVG";
   if(s=="TRENDLINE") return "TRENDLINE";
   if(s=="MIXED") return "MIXED";
   return "TRENDLINE";
}

bool HasSignal(const string id) {
   string needle = "AZT-" + id;
   for(int i=OrdersTotal()-1; i>=0; i--) {
      ulong ticket=OrderGetTicket(i);
      if(ticket>0 && (ulong)OrderGetInteger(ORDER_MAGIC)==MagicNumber && StringFind(OrderGetString(ORDER_COMMENT),needle)>=0) return true;
   }
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && (ulong)PositionGetInteger(POSITION_MAGIC)==MagicNumber && StringFind(PositionGetString(POSITION_COMMENT),needle)>=0) return true;
   }
   return false;
}

double VolumeForRisk(string symbol, ENUM_ORDER_TYPE type, double entry, double sl, double riskPct) {
   double maxLoss=AccountInfoDouble(ACCOUNT_BALANCE)*MathMin(riskPct,MaxRiskPercent)/100.0;
   double profit=0;
   ENUM_ORDER_TYPE calcType=(type==ORDER_TYPE_BUY_LIMIT ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(calcType,symbol,1.0,entry,sl,profit) || profit>=0) return 0;
   double lots=maxLoss/MathAbs(profit);
   double step=SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MAX);
   lots=MathFloor(lots/step)*step;
   lots=MathMin(lots,maxLot);
   if(lots<minLot) return 0;
   return NormalizeDouble(lots,2);
}

void QueuePartialState(string id, double tp1, double tp2) {
   GlobalVariableSet("AZT_TP1_"+id,tp1);
   GlobalVariableSet("AZT_TP2_"+id,tp2);
}

void Acknowledge(string id) {
   char data[], result[]; string responseHeaders;
   string headers="X-Api-Key: "+ApiKey+"\r\n";
   WebRequest("POST",ServerUrl+"/mt5/ack/"+id,headers,5000,data,result,responseHeaders);
}

bool IsMarketSafe(string symbol) {
   MqlTick tick;
   if(!SymbolInfoTick(symbol,tick)) return false;
   double spread = (tick.ask - tick.bid) / _Point;
   if(spread > MaxSpreadPoints) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0) return false;
   double drawdown = ((balance - equity) / balance) * 100.0;
   if(drawdown > MaxDrawdownPercent) return false;
   if(PositionsTotal() >= MaxOpenPositions) return false;
   return true;
}

bool TrendlineIsAligned(string symbol, string side) {
   int maFast = iMA(symbol,PERIOD_CURRENT,9,0,MODE_EMA,PRICE_CLOSE);
   int maSlow = iMA(symbol,PERIOD_CURRENT,21,0,MODE_EMA,PRICE_CLOSE);
   if(maFast == INVALID_HANDLE || maSlow == INVALID_HANDLE) return false;
   double fast[], slow[];
   MqlRates rateData[];
   if(CopyRates(symbol,PERIOD_CURRENT,0,TrendLookback,rateData) < TrendLookback) return false;
   if(CopyBuffer(maFast,0,0,TrendLookback,fast) < TrendLookback) return false;
   if(CopyBuffer(maSlow,0,0,TrendLookback,slow) < TrendLookback) return false;
   double lastFast = fast[TrendLookback-1];
   double lastSlow = slow[TrendLookback-1];
   if(side=="BUY") return lastFast > lastSlow;
   if(side=="SELL") return lastFast < lastSlow;
   return false;
}

bool RetestIsValid(string symbol, string side, double entry) {
   MqlRates rates[];
   int total = CopyRates(symbol,PERIOD_CURRENT,0,TrendLookback,rates);
   if(total < TrendLookback) return false;
   double low = 999999.0, high = -999999.0;
   for(int i=0; i<total; i++) {
      if(rates[i].low < low) low = rates[i].low;
      if(rates[i].high > high) high = rates[i].high;
   }
   double tolerance = (high - low) * 0.08;
   if(side=="BUY") return entry >= low && entry <= high && entry <= rates[0].close + tolerance;
   if(side=="SELL") return entry >= low && entry <= high && entry >= rates[0].close - tolerance;
   return false;
}

bool FVGIsValid(string symbol, string side) {
   if(!EnableFVGScan) return true;
   MqlRates rates[];
   int total = CopyRates(symbol,PERIOD_CURRENT,0,25,rates);
   if(total < 25) return false;
   double a = rates[2].low, b = rates[2].high, c = rates[1].low, d = rates[1].high;
   double gap = MathAbs((rates[0].close - rates[0].open));
   if(side=="BUY") return (rates[0].close > rates[1].close && d > a && gap > 0) || (rates[0].close > rates[0].open && rates[1].high > rates[2].high);
   if(side=="SELL") return (rates[0].close < rates[1].close && c < b && gap > 0) || (rates[0].close < rates[0].open && rates[1].low < rates[2].low);
   return false;
}

bool StrategyAllowed(string strategy, string side) {
   strategy = NormalizeStrategy(strategy);
   if(!IsMarketSafe(ActiveSymbol())) return false;
   if(strategy=="SCALP") return EnableScalp && TrendlineIsAligned(ActiveSymbol(),side);
   if(strategy=="SWING") return EnableSwing && RetestIsValid(ActiveSymbol(),side,MarketInfo(ActiveSymbol(),MODE_BID));
   if(strategy=="SNIPER") return EnableSniper && TrendlineIsAligned(ActiveSymbol(),side) && RetestIsValid(ActiveSymbol(),side,MarketInfo(ActiveSymbol(),MODE_BID));
   if(strategy=="FVG") return EnableFVGScan && FVGIsValid(ActiveSymbol(),side);
   if(strategy=="MIXED") return TrendlineIsAligned(ActiveSymbol(),side) || FVGIsValid(ActiveSymbol(),side);
   return EnableTrendlineScan && TrendlineIsAligned(ActiveSymbol(),side);
}

void DrawStructure() {
   if(!AutoDrawStructure) return;
   string symbol = ActiveSymbol();
   string objPrefix = "AZT_" + symbol; 
   ObjectsDeleteAll(0, objPrefix);
   MqlRates rates[];
   int total = CopyRates(symbol,PERIOD_CURRENT,0,TrendLookback,rates);
   if(total < TrendLookback) return;
   double highest = rates[0].high, lowest = rates[0].low;
   int highIdx = 0, lowIdx = 0;
   for(int i=1; i<total; i++) {
      if(rates[i].high > highest) { highest = rates[i].high; highIdx = i; }
      if(rates[i].low < lowest) { lowest = rates[i].low; lowIdx = i; }
   }
   string topLine = objPrefix + "_TOP";
   string botLine = objPrefix + "_BOT";
   if(!ObjectCreate(0, topLine, OBJ_HLINE, 0, 0, highest)) { Print("Failed to create top line for ", symbol); }
   if(!ObjectCreate(0, botLine, OBJ_HLINE, 0, 0, lowest)) { Print("Failed to create bottom line for ", symbol); }
   ObjectSetInteger(0, topLine, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, botLine, OBJPROP_COLOR, clrTomato);
   ObjectSetInteger(0, topLine, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, botLine, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetDouble(0, topLine, OBJPROP_PRICE, highest);
   ObjectSetDouble(0, botLine, OBJPROP_PRICE, lowest);
   string trend = objPrefix + "_TREND";
   if(!ObjectCreate(0, trend, OBJ_TRENDBYANGLE, 0, 0, 0)) {
      Print("Failed to create trendline object");
      return;
   }
   ObjectSetInteger(0, trend, OBJPROP_COLOR, clrLimeGreen);
   ObjectSetInteger(0, trend, OBJPROP_WIDTH, 2);
   datetime t1 = rates[total-1].time;
   datetime t0 = rates[0].time;
   double y1 = rates[total-1].close;
   double y0 = rates[0].close;
   ObjectSetDouble(0, trend, OBJPROP_TIME1, t0);
   ObjectSetDouble(0, trend, OBJPROP_TIME2, t1);
   ObjectSetDouble(0, trend, OBJPROP_PRICE1, y0);
   ObjectSetDouble(0, trend, OBJPROP_PRICE2, y1);
}

bool ProcessCommand(string response) {
   string fields[];
   int n=StringSplit(response,'|',fields);
   if(n<11 || fields[0]!="OPEN") { Print("Bad server command: ",response); return false; }
   string id = fields[1];
   string symbol = fields[2];
   string side = fields[3];
   string orderKind = fields[4];
   string strategy = (n>=12) ? NormalizeStrategy(fields[11]) : "TRENDLINE";
   if(SymbolOverride!="") symbol=SymbolOverride;
   if(!SymbolSelect(symbol,true)) { Print("Symbol unavailable: ",symbol); return false; }
   if(HasSignal(id)) return true;
   if(orderKind!="LIMIT" || (side!="BUY" && side!="SELL")) { Print("Only BUY/SELL LIMIT commands accepted"); return false; }
   if(!StrategyAllowed(strategy, side)) { Print("Signal blocked by strategy/risk gate: ",strategy); return false; }
   double entry=StringToDouble(fields[5]), sl=StringToDouble(fields[6]);
   double tp1=StringToDouble(fields[7]), tp2=StringToDouble(fields[8]), tp3=StringToDouble(fields[9]), risk=StringToDouble(fields[10]);
   MqlTick tick; if(!SymbolInfoTick(symbol,tick)) return false;
   if((side=="BUY" && entry>=tick.ask) || (side=="SELL" && entry<=tick.bid)) { Print("Limit entry is already crossed; rejecting stale signal."); return false; }
   ENUM_ORDER_TYPE type=(side=="BUY" ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   double vol=VolumeForRisk(symbol,type,entry,sl,risk);
   if(vol<=0) { Print("Order rejected: volume below broker minimum or invalid SL."); return false; }
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   string comment="AZT-"+id;
   bool ok=(side=="BUY") ? trade.BuyLimit(vol,entry,symbol,sl,tp3,ORDER_TIME_GTC,0,comment)
                            : trade.SellLimit(vol,entry,symbol,sl,tp3,ORDER_TIME_GTC,0,comment);
   if(!ok) { Print("Order failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription()); return false; }
   QueuePartialState(id,tp1,tp2);
   Acknowledge(id);
   Print("Approved signal placed: ",comment," strategy=",strategy," volume=",vol," TP1=",tp1," TP2=",tp2," TP3=",tp3);
   return true;
}

bool RunSelfTest() {
   char data[], result[]; string responseHeaders;
   string headers="X-Api-Key: "+ApiKey+"\r\n";
   int code=WebRequest("GET",ServerUrl+"/mt5/test",headers,5000,data,result,responseHeaders);
   if(code!=-1 && code==200) {
      string response=CharArrayToString(result);
      Print("SELFTEST OK: ",response);
      return true;
   }
   Print("SELFTEST FAIL: server monitor not responding. HTTP=",code," LastError=",GetLastError());
   return false;
}

void PollServer() {
   char data[], result[]; string responseHeaders;
   string headers="X-Api-Key: "+ApiKey+"\r\n";
   ResetLastError();
   int code=WebRequest("GET",ServerUrl+"/mt5/next",headers,5000,data,result,responseHeaders);
   if(code==-1) { Print("WebRequest error ",GetLastError(),". Add ServerUrl in MT5 Options > Expert Advisors."); return; }
   if(code!=200) { Print("Server response HTTP ",code); return; }
   string response=CharArrayToString(result);
   StringTrimLeft(response); StringTrimRight(response);
   if(response!="" && response!="NONE") ProcessCommand(response);
}

void ManagePartialCloses() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i); if(ticket==0) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      double volume=PositionGetDouble(POSITION_VOLUME);
      string comment=PositionGetString(POSITION_COMMENT);
      int marker=StringFind(comment,"AZT-");
      if(marker<0) continue;
      string id=StringSubstr(comment,marker+4);
      string key1="AZT_TP1_"+id, key2="AZT_TP2_"+id;
      if(!GlobalVariableCheck(key1) || !GlobalVariableCheck(key2)) continue;
      double tp1=GlobalVariableGet(key1), tp2=GlobalVariableGet(key2);
      MqlTick tick; if(!SymbolInfoTick(symbol,tick)) continue;
      bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
      double price=buy?tick.bid:tick.ask;
      if(GlobalVariableGet("AZT_STAGE_"+(string)ticket)<1 && ((buy && price>=tp1)||(!buy && price<=tp1))) {
         double closeVol=NormalizeDouble(volume*0.50,2);
         if(closeVol>=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN) && trade.PositionClosePartial(ticket,closeVol)) GlobalVariableSet("AZT_STAGE_"+(string)ticket,1);
      } else if(GlobalVariableGet("AZT_STAGE_"+(string)ticket)<2 && ((buy && price>=tp2)||(!buy && price<=tp2))) {
         double closeVol=NormalizeDouble(volume*0.60,2);
         if(closeVol>=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN) && trade.PositionClosePartial(ticket,closeVol)) GlobalVariableSet("AZT_STAGE_"+(string)ticket,2);
      }
   }
}

int OnInit() {
   if(StringFind(ServerUrl,"YOUR_DOMAIN")>=0 || ApiKey=="CHANGE_ME") { Print("Configure ServerUrl and ApiKey first."); return INIT_PARAMETERS_INCORRECT; }
   trade.SetExpertMagicNumber(MagicNumber);
   EventSetTimer(PollSeconds);
   if(AutoDrawStructure) DrawStructure();
   RunSelfTest();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer() {
   if(AutoDrawStructure) DrawStructure();
   RunSelfTest();
   PollServer();
   ManagePartialCloses();
}
void OnTick() {
   if(AutoDrawStructure) DrawStructure();
   RunSelfTest();
   ManagePartialCloses();
}
