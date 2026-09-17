//+------------------------------------------------------------------+
//| AI Zone Trader EA: Telegram-confirmed pending orders only.      |
//| Add ServerUrl to MT5 Allow WebRequest URLs before attaching.    |
//+------------------------------------------------------------------+
#property strict
#property version   "0.1"
#include <Trade/Trade.mqh>

input string ServerUrl = "https://YOUR_DOMAIN";
input string ApiKey = "CHANGE_ME";
input string SymbolOverride = "";              // e.g. XAUUSD.a; blank = current chart
input double MaxRiskPercent = 0.50;
input int PollSeconds = 10;
input ulong MagicNumber = 260916;
input int SlippagePoints = 30;

CTrade trade;

string ActiveSymbol() { return SymbolOverride == "" ? _Symbol : SymbolOverride; }

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
   if(lots<minLot) return 0; // Do not exceed intended risk merely to meet broker minimum.
   return NormalizeDouble(lots,2);
}

void QueuePartialState(string id, double tp1, double tp2) {
   // The broker preserves our comment when the pending order becomes a position.
   GlobalVariableSet("AZT_TP1_"+id,tp1);
   GlobalVariableSet("AZT_TP2_"+id,tp2);
}

void Acknowledge(string id) {
   char data[], result[]; string responseHeaders;
   string headers="X-Api-Key: "+ApiKey+"\r\n";
   WebRequest("POST",ServerUrl+"/mt5/ack/"+id,headers,5000,data,result,responseHeaders);
}

bool ProcessCommand(string response) {
   string fields[];
   int n=StringSplit(response,'|',fields);
   if(n!=11 || fields[0]!="OPEN") { Print("Bad server command: ",response); return false; }
   string id=fields[1], symbol=fields[2], side=fields[3], orderKind=fields[4];
   if(SymbolOverride!="") symbol=SymbolOverride;
   if(!SymbolSelect(symbol,true)) { Print("Symbol unavailable: ",symbol); return false; }
   if(HasSignal(id)) return true;
   if(orderKind!="LIMIT" || (side!="BUY" && side!="SELL")) { Print("Only BUY/SELL LIMIT commands accepted"); return false; }
   double entry=StringToDouble(fields[5]), sl=StringToDouble(fields[6]);
   double tp1=StringToDouble(fields[7]), tp2=StringToDouble(fields[8]), tp3=StringToDouble(fields[9]), risk=StringToDouble(fields[10]);
   ENUM_ORDER_TYPE type=(side=="BUY" ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   double vol=VolumeForRisk(symbol,type,entry,sl,risk);
   if(vol<=0) { Print("Order rejected: calculated volume below broker minimum or invalid SL."); return false; }
   MqlTick tick; if(!SymbolInfoTick(symbol,tick)) return false;
   // Prevent an unintended immediate execution: a LIMIT must remain on the correct side of price.
   if((side=="BUY" && entry>=tick.ask) || (side=="SELL" && entry<=tick.bid)) { Print("Limit entry is already crossed; rejecting stale signal."); return false; }
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   string comment="AZT-"+id;
   bool ok=(side=="BUY") ? trade.BuyLimit(vol,entry,symbol,sl,tp3,ORDER_TIME_GTC,0,comment)
                            : trade.SellLimit(vol,entry,symbol,sl,tp3,ORDER_TIME_GTC,0,comment);
   if(!ok) { Print("Order failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription()); return false; }
   QueuePartialState(id,tp1,tp2);
   Acknowledge(id);
   Print("Approved signal placed: ",comment," volume=",vol," TP1=",tp1," TP2=",tp2," TP3=",tp3);
   return true;
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
      double tp3=PositionGetDouble(POSITION_TP), volume=PositionGetDouble(POSITION_VOLUME);
      // Position ticket is normally different from its originating pending-order ticket.
      // TP1/TP2 are reconstructed from original risk only if values were copied externally;
      // this conservative fallback keeps TP3 on broker side and avoids unsafe guessing.
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
         double closeVol=NormalizeDouble(volume*0.60,2); // 30% of original after TP1
         if(closeVol>=SymbolInfoDouble(symbol,SYMBOL_VOLUME_MIN) && trade.PositionClosePartial(ticket,closeVol)) GlobalVariableSet("AZT_STAGE_"+(string)ticket,2);
      }
   }
}

int OnInit() {
   if(StringFind(ServerUrl,"YOUR_DOMAIN")>=0 || ApiKey=="CHANGE_ME") { Print("Configure ServerUrl and ApiKey first."); return INIT_PARAMETERS_INCORRECT; }
   trade.SetExpertMagicNumber(MagicNumber);
   EventSetTimer(PollSeconds);
   return INIT_SUCCEEDED;
}
void OnDeinit(const int reason) { EventKillTimer(); }
void OnTimer() { PollServer(); ManagePartialCloses(); }
void OnTick() { ManagePartialCloses(); }
