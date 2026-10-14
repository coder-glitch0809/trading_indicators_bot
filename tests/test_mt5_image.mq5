// Offline visual QA: no EA init, no WebRequest, no trading calls.
#define OnInit EA_OnInit
#define OnDeinit EA_OnDeinit
#define OnTick EA_OnTick
#define OnTimer EA_OnTimer
#include "../mt5/AI_Zone_Trader_EA.mq5"
#undef OnInit
#undef OnDeinit
#undef OnTick
#undef OnTimer
void OnStart() {
   TF=PERIOD_M1; Prefix="AZT_QA_"; ArraySetAsSeries(Rates,true);
   int n=CopyRates(_Symbol,TF,0,160,Rates);
   if(n<100) { Print("IMAGE_QA insufficient cached candles: ",n); return; }
   LocalSignal s; ZeroMemory(s); s.time=Rates[1].time; s.side=-1;
   s.entry=Rates[1].close; s.atr=0.001; s.sl=s.entry+0.002;
   s.tp1=s.entry-0.003; s.tp2=s.entry-0.0045; s.tp3=s.entry-0.006;
   s.setup="OFFLINE PREVIEW - NOT A LIVE SIGNAL"; s.score=2;
   AZTTG_Ready=true; AZTTG_Scope="IMAGE_QA";
   QueueSignalImage(s,"offline-preview");
   Sleep(2000);
   if(ArraySize(AZTTG_Queue)>0) Print("IMAGE_QA ",AZTTG_Queue[0].photo," exists=",FileIsExist(AZTTG_Queue[0].photo));
}
