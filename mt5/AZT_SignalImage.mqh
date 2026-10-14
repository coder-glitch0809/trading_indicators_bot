#ifndef AZT_SIGNAL_IMAGE_MQH
#define AZT_SIGNAL_IMAGE_MQH
input bool InpSignalImages=true; // Telegram: real chart PNG + detailed text
void AZTImageLevel(long chart,string label,double price,color ink) {
   string name="AZT_IMG_"+label;
   ObjectCreate(chart,name,OBJ_HLINE,0,0,price);
   ObjectSetInteger(chart,name,OBJPROP_COLOR,ink);
   ObjectSetInteger(chart,name,OBJPROP_WIDTH,2);
   ObjectSetString(chart,name,OBJPROP_TEXT,label+" "+Price(price));
   string text=name+"_label";
   ObjectCreate(chart,text,OBJ_TEXT,0,Rates[MathMin(70,ArraySize(Rates)-1)].time,price);
   ObjectSetString(chart,text,OBJPROP_TEXT,label+"  "+Price(price));
   ObjectSetString(chart,text,OBJPROP_FONT,"Arial");
   ObjectSetInteger(chart,text,OBJPROP_FONTSIZE,12);
   ObjectSetInteger(chart,text,OBJPROP_COLOR,ink);
   ObjectSetInteger(chart,text,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
}
void QueueSignalImage(const LocalSignal &signal,const string key) {
   if(!InpSignalImages || !AZTTelegramReady() || ArraySize(Rates)<3) return;
   long chart=ChartOpen(_Symbol,TF);
   if(chart==0) { Print("AZT: chart image unavailable"); return; }
   ChartSetInteger(chart,CHART_MODE,CHART_CANDLES);
   ChartSetInteger(chart,CHART_COLOR_BACKGROUND,C'15,18,32');
   ChartSetInteger(chart,CHART_COLOR_FOREGROUND,clrSilver);
   ChartSetInteger(chart,CHART_COLOR_CANDLE_BULL,C'20,195,145');
   ChartSetInteger(chart,CHART_COLOR_CHART_UP,C'20,195,145');
   ChartSetInteger(chart,CHART_COLOR_CANDLE_BEAR,C'240,75,90');
   ChartSetInteger(chart,CHART_COLOR_CHART_DOWN,C'240,75,90');
   ChartSetInteger(chart,CHART_SHOW_GRID,false);
   ChartSetInteger(chart,CHART_SHOW_VOLUMES,CHART_VOLUME_HIDE);
   ChartSetInteger(chart,CHART_SHOW_TRADE_LEVELS,false);
   ChartSetInteger(chart,CHART_SHOW_OBJECT_DESCR,true);
   ChartSetInteger(chart,CHART_AUTOSCROLL,true);
   ChartSetInteger(chart,CHART_SHIFT,true);
   ChartSetInteger(chart,CHART_SCALE,3);
   double lo=MathMin(signal.sl,signal.tp3), hi=MathMax(signal.sl,signal.tp3);
   for(int i=0;i<MathMin(100,ArraySize(Rates));i++) { lo=MathMin(lo,Rates[i].low); hi=MathMax(hi,Rates[i].high); }
   double pad=MathMax((hi-lo)*0.12,signal.atr);
   ChartSetInteger(chart,CHART_SCALEFIX,true);
   ChartSetDouble(chart,CHART_FIXED_MIN,lo-pad);
   ChartSetDouble(chart,CHART_FIXED_MAX,hi+pad);
   AZTImageLevel(chart,"ENTRY",signal.entry,clrWhite);
   AZTImageLevel(chart,"SL",signal.sl,clrTomato);
   AZTImageLevel(chart,"TP1",signal.tp1,clrLimeGreen);
   AZTImageLevel(chart,"TP2",signal.tp2,clrLimeGreen);
   AZTImageLevel(chart,"TP3",signal.tp3,clrLimeGreen);
   AZTLevel levels[]; BuildLevels(1,signal.atr,levels);
   for(int i=0;i<MathMin(6,ArraySize(levels));i++)
      AZTImageLevel(chart,"SNR "+(string)levels[i].touches+"x",levels[i].price,clrSlateGray);
   // Copy only the strategy's trend lines, never account/UI objects.
   for(int i=0;i<ObjectsTotal(0);i++) {
      string name=ObjectName(0,i);
      if(StringFind(name,Prefix)!=0 || ObjectGetInteger(0,name,OBJPROP_TYPE)!=OBJ_TREND) continue;
      ObjectCreate(chart,name,OBJ_TREND,0,(datetime)ObjectGetInteger(0,name,OBJPROP_TIME,0),ObjectGetDouble(0,name,OBJPROP_PRICE,0),
         (datetime)ObjectGetInteger(0,name,OBJPROP_TIME,1),ObjectGetDouble(0,name,OBJPROP_PRICE,1));
      ObjectSetInteger(chart,name,OBJPROP_COLOR,clrOrange);
      ObjectSetInteger(chart,name,OBJPROP_WIDTH,2);
      ObjectSetInteger(chart,name,OBJPROP_RAY_RIGHT,ObjectGetInteger(0,name,OBJPROP_RAY_RIGHT));
   }
   string title=_Symbol+" | "+StringSubstr(EnumToString(TF),7)+" | "+(signal.side==1 ? "BUY" : "SELL")+
      " | "+TimeToString(signal.time+PeriodSeconds(TF),TIME_DATE|TIME_SECONDS)+" broker";
   ObjectCreate(chart,"AZT_IMG_TITLE",OBJ_LABEL,0,0,0);
   ObjectSetInteger(chart,"AZT_IMG_TITLE",OBJPROP_XDISTANCE,20);
   ObjectSetInteger(chart,"AZT_IMG_TITLE",OBJPROP_YDISTANCE,25);
   ObjectSetInteger(chart,"AZT_IMG_TITLE",OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(chart,"AZT_IMG_TITLE",OBJPROP_FONTSIZE,14);
   ObjectSetString(chart,"AZT_IMG_TITLE",OBJPROP_TEXT,title);
   ObjectCreate(chart,"AZT_IMG_SETUP",OBJ_LABEL,0,0,0);
   ObjectSetInteger(chart,"AZT_IMG_SETUP",OBJPROP_XDISTANCE,20);
   ObjectSetInteger(chart,"AZT_IMG_SETUP",OBJPROP_YDISTANCE,52);
   ObjectSetInteger(chart,"AZT_IMG_SETUP",OBJPROP_COLOR,clrGold);
   ObjectSetInteger(chart,"AZT_IMG_SETUP",OBJPROP_FONTSIZE,11);
   ObjectSetString(chart,"AZT_IMG_SETUP",OBJPROP_TEXT,signal.setup);
   ChartNavigate(chart,CHART_END,0);
   ChartRedraw(chart);
   string file="AZT_signal_"+AZTTelegramHash(key)+".png";
   bool saved=ChartScreenShot(chart,file,1600,900,ALIGN_RIGHT);
   // Synchronous property read drains preceding chart commands before closing.
   ChartGetInteger(chart,CHART_WIDTH_IN_PIXELS);
   ChartClose(chart);
   string caption="YANGI SIGNAL | "+title+"\nEntry "+Price(signal.entry)+" | SL "+Price(signal.sl)+
      "\nTP1 "+Price(signal.tp1)+" | TP2 "+Price(signal.tp2)+" | TP3 "+Price(signal.tp3)+
      "\nSetup: "+signal.setup+" | Konfluens: "+(string)signal.score+"\nBatafsil tahlil keyingi xabarda.";
   if(!saved || !AZTTelegramQueuePhoto("img|"+key,caption,file)) { FileDelete(file); Print("AZT: signal image not queued"); }
}
#endif
