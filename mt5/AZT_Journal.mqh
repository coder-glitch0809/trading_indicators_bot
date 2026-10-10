// Signal journal = the AIs' memory. Every live signal is stored with both AI
// verdicts, then scored on real closed candles with the 3-part exit plan.
// Each AI is shown its own record next time; after a wrong call it writes a lesson.
// File: MQL5/Files/AZT_Journal_<symbol>_<tf>.csv (one per chart symbol/timeframe).
// Include after AZT_History.mqh and AZT_AI.mqh.
#ifndef AZT_JOURNAL_MQH
#define AZT_JOURNAL_MQH

#define AZT_JOURNAL_MAX 300

struct AZTJournalRow {
   string id;
   datetime time;
   int side;
   string setup, context, action;
   double entry, sl;
   int dec[AZT_AI_COUNT], conf[AZT_AI_COUNT];
   string why[AZT_AI_COUNT];
   int outcome;     // 0 pending, 1 reached TP1 before SL, -1 SL before TP1, 2 neither (time limit)
   int stage;       // targets reached 0..3
   double resultR, mfeR, maeR;
   int reflected;   // bit per provider: lesson already written
};
AZTJournalRow Journal[];
datetime JournalNextReflect=0;

string JournalFile() { return "AZT_Journal_"+_Symbol+"_"+StringSubstr(EnumToString(TF),7)+".csv"; }

string JournalClean(string value,int limit=300) {
   StringReplace(value,";",","); StringReplace(value,"\n"," "); StringReplace(value,"\r"," ");
   return AZTTrimTo(value,limit);
}

void JournalSave() {
   int file=FileOpen(JournalFile(),FILE_WRITE|FILE_CSV|FILE_ANSI,';',CP_UTF8);
   if(file==INVALID_HANDLE) { Print("AZT: cannot write journal ",GetLastError()); return; }
   FileWrite(file,"id","time","side","setup","context","action","entry","sl",
      "claude","claude_conf","claude_why","gemini","gemini_conf","gemini_why",
      "outcome","stage","resultR","mfeR","maeR","reflected");
   for(int i=0;i<ArraySize(Journal);i++) {
      AZTJournalRow r=Journal[i];
      FileWrite(file,r.id,(long)r.time,r.side,r.setup,r.context,r.action,
         DoubleToString(r.entry,_Digits),DoubleToString(r.sl,_Digits),
         r.dec[0],r.conf[0],r.why[0],r.dec[1],r.conf[1],r.why[1],
         r.outcome,r.stage,DoubleToString(r.resultR,3),DoubleToString(r.mfeR,2),DoubleToString(r.maeR,2),r.reflected);
   }
   FileClose(file);
}

void JournalLoad() {
   ArrayResize(Journal,0);
   int file=FileOpen(JournalFile(),FILE_READ|FILE_CSV|FILE_ANSI|FILE_SHARE_READ,';',CP_UTF8);
   if(file==INVALID_HANDLE) return;
   for(int c=0;c<20 && !FileIsEnding(file);c++) FileReadString(file); // header
   while(!FileIsEnding(file)) {
      AZTJournalRow r;
      r.id=FileReadString(file);
      if(r.id=="") { if(FileIsLineEnding(file)) continue; break; }
      r.time=(datetime)StringToInteger(FileReadString(file));
      r.side=(int)StringToInteger(FileReadString(file));
      r.setup=FileReadString(file); r.context=FileReadString(file); r.action=FileReadString(file);
      r.entry=StringToDouble(FileReadString(file)); r.sl=StringToDouble(FileReadString(file));
      for(int p=0;p<AZT_AI_COUNT;p++) {
         r.dec[p]=(int)StringToInteger(FileReadString(file));
         r.conf[p]=(int)StringToInteger(FileReadString(file));
         r.why[p]=FileReadString(file);
      }
      r.outcome=(int)StringToInteger(FileReadString(file));
      r.stage=(int)StringToInteger(FileReadString(file));
      r.resultR=StringToDouble(FileReadString(file));
      r.mfeR=StringToDouble(FileReadString(file));
      r.maeR=StringToDouble(FileReadString(file));
      r.reflected=(int)StringToInteger(FileReadString(file));
      int n=ArraySize(Journal); ArrayResize(Journal,n+1); Journal[n]=r;
   }
   FileClose(file);
}

int JournalFind(const string id) {
   for(int i=ArraySize(Journal)-1;i>=0;i--) if(Journal[i].id==id) return i;
   return -1;
}

void JournalAdd(const string id,const LocalSignal &signal,const string context,const AZTAIVerdict &verdicts[],const string action) {
   if(JournalFind(id)>=0) return;
   int n=ArraySize(Journal);
   if(n>=AZT_JOURNAL_MAX) { ArrayRemove(Journal,0,n-AZT_JOURNAL_MAX+1); n=ArraySize(Journal); }
   ArrayResize(Journal,n+1);
   ZeroMemory(Journal[n]);
   Journal[n].id=id; Journal[n].time=signal.time; Journal[n].side=signal.side;
   Journal[n].setup=JournalClean(signal.setup,60); Journal[n].context=JournalClean(context,300);
   Journal[n].action=action; Journal[n].entry=signal.entry; Journal[n].sl=signal.sl;
   for(int p=0;p<AZT_AI_COUNT;p++) {
      Journal[n].dec[p]=verdicts[p].ok ? verdicts[p].decision : 0;
      Journal[n].conf[p]=verdicts[p].ok ? verdicts[p].confidence : 0;
      Journal[n].why[p]=JournalClean(verdicts[p].summary,250);
   }
   JournalSave();
}

void JournalSetAction(const string id,const string action) {
   int i=JournalFind(id);
   if(i<0) return;
   Journal[i].action=action;
   JournalSave();
}

// 1 right, -1 wrong, 0 not judged (no verdict, pending, or neutral outcome).
int JournalCorrect(const AZTJournalRow &r,int provider) {
   if(r.dec[provider]==0 || (r.outcome!=1 && r.outcome!=-1)) return 0;
   return r.dec[provider]==r.outcome ? 1 : -1;
}

string OutcomeText(const AZTJournalRow &r) {
   if(r.outcome==0) return "kutilmoqda";
   string stages=r.stage>=3 ? "TP1 ✓ TP2 ✓ TP3 ✓" : r.stage==2 ? "TP1 ✓ TP2 ✓, qolgani TP1 da yopildi" :
                 r.stage==1 ? "TP1 ✓, qolgani zararsiz (entry) da yopildi" : r.outcome==-1 ? "SL urildi" : "vaqt tugadi";
   return stages+" → "+(r.resultR>=0 ? "+" : "")+DoubleToString(r.resultR,2)+"R";
}

// APPROVE accuracy of `provider` over its newest judged approvals.
double JournalApprovePrecision(int provider,int &samples,int newest=20) {
   samples=0; int right=0;
   for(int i=ArraySize(Journal)-1;i>=0 && samples<newest;i--) {
      if(Journal[i].dec[provider]!=1) continue;
      int c=JournalCorrect(Journal[i],provider);
      if(c==0) continue;
      samples++; if(c>0) right++;
   }
   return samples>0 ? 100.0*right/samples : 0;
}

string JournalScore(int provider) {
   int approvals=0, approvalsRight=0, rejects=0, rejectsRight=0;
   for(int i=0;i<ArraySize(Journal);i++) {
      int c=JournalCorrect(Journal[i],provider);
      if(c==0) continue;
      if(Journal[i].dec[provider]==1) { approvals++; if(c>0) approvalsRight++; }
      else { rejects++; if(c>0) rejectsRight++; }
   }
   if(approvals+rejects==0) return AZTAIName(provider)+": hali baholangan signal yo'q";
   return AZTAIName(provider)+": to'g'ri "+(string)(approvalsRight+rejectsRight)+"/"+(string)(approvals+rejects)+
      " ("+DoubleToString(100.0*(approvalsRight+rejectsRight)/(approvals+rejects),0)+"%) | APPROVE "+
      (string)approvalsRight+"/"+(string)approvals+" | REJECT "+(string)rejectsRight+"/"+(string)rejects;
}

// The provider's own memory, appended to its prompt.
string JournalMemory(int provider,int newest=15) {
   string lines="";
   int shown=0;
   for(int i=ArraySize(Journal)-1;i>=0 && shown<newest;i--) {
      AZTJournalRow r=Journal[i];
      int c=JournalCorrect(r,provider);
      if(c==0) continue;
      lines="\n- "+TimeToString(r.time,TIME_DATE|TIME_MINUTES)+" "+(r.side==1 ? "BUY" : "SELL")+" "+r.setup+
            " | "+r.context+" | you said "+(r.dec[provider]==1 ? "APPROVE" : "REJECT")+" "+(string)r.conf[provider]+
            "% | result: "+(r.outcome==1 ? "reached 1.5R" : "hit SL first")+" | "+(c>0 ? "RIGHT" : "WRONG")+lines;
      shown++;
   }
   string text="\n\nYOUR OWN TRACK RECORD ("+AZTAIName(provider)+") on "+_Symbol+" "+EnumToString(TF)+": "+
               JournalScore(provider)+(lines=="" ? "" : lines);
   string lessons=AZTLessonsText(provider);
   if(lessons!="") text+="\n\nLESSONS YOU WROTE AFTER YOUR PAST MISTAKES (apply them):"+lessons;
   return text;
}

// Scores pending rows on closed candles. Returns indexes that just resolved.
int JournalResolve(int &resolved[]) {
   ArrayResize(resolved,0);
   bool changed=false;
   for(int i=0;i<ArraySize(Journal);i++) {
      if(Journal[i].outcome!=0) continue;
      int shift=iBarShift(_Symbol,TF,Journal[i].time,true);
      if(shift<0 || shift>=ArraySize(Rates)) { Journal[i].outcome=2; changed=true; continue; }
      if(shift<2) continue;
      double resultR; int stage, exitShift;
      AZTHistoryOutcome outcome=SimulatePlan(Journal[i].side,Journal[i].entry,Journal[i].sl,shift-1,
                                             HistoryMaxHoldingBars,resultR,stage,exitShift);
      if(outcome==AZT_HISTORY_PENDING) continue;
      if(outcome==AZT_HISTORY_INVALID_ENTRY) { Journal[i].outcome=2; changed=true; continue; }
      double risk=MathAbs(Journal[i].entry-Journal[i].sl), mfe=0, mae=0;
      for(int k=shift-1;k>=exitShift;k--) {
         double up=Journal[i].side==1 ? Rates[k].high-Journal[i].entry : Journal[i].entry-Rates[k].low;
         double down=Journal[i].side==1 ? Journal[i].entry-Rates[k].low : Rates[k].high-Journal[i].entry;
         mfe=MathMax(mfe,up/risk); mae=MathMax(mae,down/risk);
      }
      Journal[i].stage=stage; Journal[i].resultR=resultR; Journal[i].mfeR=mfe; Journal[i].maeR=mae;
      Journal[i].outcome=stage>=1 ? 1 : resultR<0 ? -1 : 2;
      changed=true;
      int n=ArraySize(resolved); ArrayResize(resolved,n+1); resolved[n]=i;
   }
   if(changed) JournalSave();
   return ArraySize(resolved);
}

string JournalResultText(int i) {
   AZTJournalRow r=Journal[i];
   string text="📘 SIGNAL NATIJASI | "+_Symbol+" "+EnumToString(TF)+"\n"+(r.side==1 ? "BUY" : "SELL")+" | "+r.setup+
      " | "+TimeToString(r.time)+"\n"+OutcomeText(r)+" (reja bo'yicha, shamlar asosida)"+
      "\nEng yaxshi harakat: +"+DoubleToString(r.mfeR,2)+"R | eng yomon: -"+DoubleToString(r.maeR,2)+"R"+
      "\nQaror: "+r.action;
   for(int p=0;p<AZT_AI_COUNT;p++) {
      if(r.dec[p]==0) continue;
      int c=JournalCorrect(r,p);
      text+="\n"+AZTAIName(p)+": "+(r.dec[p]==1 ? "APPROVE" : "REJECT")+" "+(string)r.conf[p]+"% → "+
            (c>0 ? "✓ to'g'ri" : c<0 ? "✗ xato (saboq yozadi)" : "baholanmaydi");
   }
   for(int p=0;p<AZT_AI_COUNT;p++) if(r.dec[p]!=0) text+="\n"+JournalScore(p);
   return text;
}

// One lesson per call (rate-limited): the wrong AI explains its own mistake.
void JournalReflectOne() {
   if(!InpAILearnFromMistakes || AZTAITester() || TimeLocal()<JournalNextReflect) return;
   for(int i=ArraySize(Journal)-1;i>=0;i--) {
      if(Journal[i].outcome!=1 && Journal[i].outcome!=-1) continue;
      if(TimeCurrent()-Journal[i].time>7*86400) break; // old backlog is skipped
      for(int p=0;p<AZT_AI_COUNT;p++) {
         if((Journal[i].reflected & (1<<p))!=0 || JournalCorrect(Journal[i],p)>=0 || !AZTAIHasKey(p)) continue;
         JournalNextReflect=TimeLocal()+60;
         AZTJournalRow r=Journal[i];
         string facts=_Symbol+" "+EnumToString(TF)+" "+TimeToString(r.time)+" "+(r.side==1 ? "BUY" : "SELL")+
            " setup: "+r.setup+"\nEntry "+DoubleToString(r.entry,_Digits)+" SL "+DoubleToString(r.sl,_Digits)+
            "\nContext at signal: "+r.context+
            "\nYou answered: "+(r.dec[p]==1 ? "APPROVE" : "REJECT")+" "+(string)r.conf[p]+"% because: "+r.why[p]+
            "\nWhat really happened: "+(r.outcome==1 ? "price reached 1.5R before the stop" : "the stop was hit before 1.5R")+
            "; best move +"+DoubleToString(r.mfeR,2)+"R, worst -"+DoubleToString(r.maeR,2)+"R.";
         string lesson;
         bool ok=AZTAIReflect(p,facts,lesson);
         Journal[i].reflected|=(1<<p); // one attempt only: never loop on a failing API
         JournalSave();
         Print("AZT: ",AZTAIName(p),ok ? " lesson: "+lesson : " could not write a lesson");
         return;
      }
   }
}
#endif
