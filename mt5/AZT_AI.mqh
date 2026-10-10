#ifndef AZT_AI_MQH
#define AZT_AI_MQH
// Claude and Gemini review every rule-based signal and learn from their own
// mistakes: each provider sees its own track record and its own lessons file.
// Keys and optional model names live in MQL5/Files/AZT_Config.ini:
//   CLAUDE_API_KEY, GEMINI_API_KEY, CLAUDE_MODEL, GEMINI_MODEL
// MT5 must allow WebRequest to https://api.anthropic.com and
// https://generativelanguage.googleapis.com. Disabled in Strategy Tester.
#include "AZT_Json.mqh"

input group "8. AI (Claude + Gemini)"
input bool InpAIEnabled = true;
input int InpAITimeoutMs = 25000;          // Per provider; the EA waits meanwhile
input int InpAIAutoConfidence = 75;        // Hybrid: both AIs >= this => trades alone
input double InpAIMinPrecision = 50;       // Hybrid: AI with worse recent APPROVE accuracy (%) must ask you
input bool InpAILearnFromMistakes = true;  // After a wrong call the AI writes itself a lesson

#define AZT_AI_COUNT 2
#define AZT_AI_CLAUDE 0
#define AZT_AI_GEMINI 1

struct AZTAIVerdict {
   bool ok;            // Provider answered with a parseable verdict
   int decision;       // 1 APPROVE, -1 REJECT, 0 unknown
   int confidence;     // 0..100
   string summary, risk, error;
};

string AZTAI_Key[AZT_AI_COUNT], AZTAI_Model[AZT_AI_COUNT];
string AZTAI_Status="Not initialized";

const string AZT_AI_SYSTEM=
   "You are a strict, risk-averse reviewer of forex/CFD/metal trades. A rule-based MetaTrader 5 EA "
   "proposes one trade with a fixed stop-loss and a 3-part exit: 50% closed at 1.5R (stop then moves to "
   "entry), 25% at 2.25R (stop moves to 1.5R), last 25% at 3R. Using ONLY the data provided, judge whether "
   "price is likely to reach at least 1.5R before the stop. REJECT when: it fights the higher-timeframe "
   "trend; an opposing order block, swing high/low or round level sits close in front of entry; price is "
   "extended (buy after a long rally with high RSI, sell after a long drop with low RSI); volatility or "
   "spread looks abnormal; or the evidence is mixed. APPROVE only clear, aligned setups. Your own past "
   "results and lessons are included: do not repeat the same mistake. Never invent news or data. "
   "Answer with ONLY this JSON, no markdown: "
   "{\"decision\":\"APPROVE\" or \"REJECT\",\"confidence\":0-100,"
   "\"summary\":\"max 350 chars, Uzbek (Latin script): why\",\"risk\":\"max 150 chars, Uzbek (Latin): main risk\"}";

const string AZT_AI_REFLECT=
   "You review your own earlier trading decision that turned out WRONG. From the facts given, write ONE "
   "short, concrete, reusable rule that would have prevented this mistake (for example about higher-timeframe "
   "trend, distance to an opposing level, RSI extremes, setup type or session). No generic advice. "
   "Answer with ONLY this JSON: {\"lesson\":\"max 200 chars, Uzbek (Latin script)\"}";

string AZTAIName(const int provider) { return provider==AZT_AI_CLAUDE ? "Claude" : "Gemini"; }

bool AZTAITester() { return MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION); }

bool AZTAIHasKey(const int provider) { return AZTAI_Key[provider]!=""; }

int AZTAIProviders() { return (AZTAIHasKey(0) ? 1 : 0)+(AZTAIHasKey(1) ? 1 : 0); }

string AZTAIStatus() { return AZTAI_Status; }

void AZTAIInit() {
   for(int i=0;i<AZT_AI_COUNT;i++) { AZTAI_Key[i]=""; AZTAI_Model[i]=""; }
   if(AZTAITester()) { AZTAI_Status="Disabled in Strategy Tester"; return; }
   if(!InpAIEnabled) { AZTAI_Status="OFF"; return; }
   AZTAI_Key[AZT_AI_CLAUDE]=AZTConfigValue("CLAUDE_API_KEY");
   if(AZTAI_Key[AZT_AI_CLAUDE]=="") AZTAI_Key[AZT_AI_CLAUDE]=AZTConfigValue("ANTHROPIC_API_KEY");
   AZTAI_Key[AZT_AI_GEMINI]=AZTConfigValue("GEMINI_API_KEY");
   AZTAI_Model[AZT_AI_CLAUDE]=AZTConfigValue("CLAUDE_MODEL");
   AZTAI_Model[AZT_AI_GEMINI]=AZTConfigValue("GEMINI_MODEL");
   if(AZTAI_Model[AZT_AI_CLAUDE]=="") AZTAI_Model[AZT_AI_CLAUDE]="claude-sonnet-5-5";
   if(AZTAI_Model[AZT_AI_GEMINI]=="") AZTAI_Model[AZT_AI_GEMINI]="gemini-2.5-flash";
   AZTAI_Status="";
   for(int i=0;i<AZT_AI_COUNT;i++)
      AZTAI_Status+=(i>0 ? " | " : "")+AZTAIName(i)+" "+(AZTAIHasKey(i) ? AZTAI_Model[i] : "NO KEY");
}

int AZTAIPost(const string url,const string headers,const string body,string &result,int &error) {
   char request[],response[];
   int bytes=StringToCharArray(body,request,0,WHOLE_ARRAY,CP_UTF8);
   ArrayResize(request,MathMax(0,bytes-1));
   string response_headers;
   ResetLastError();
   int http=WebRequest("POST",url,headers,MathMax(3000,MathMin(InpAITimeoutMs,60000)),request,response,response_headers);
   error=GetLastError();
   result=CharArrayToString(response,0,WHOLE_ARRAY,CP_UTF8);
   return http;
}

string AZTAIHttpError(const int http,const int error,const string result,const string host) {
   if(http==-1 && error==4014) return "MT5: Tools > Options > Expert Advisors ga https://"+host+" qo'shing";
   if(http==-1) return "Internet/timeout (MT5 "+(string)error+")";
   string message=AZTJsonString(result,"message");
   if(http==401 || http==403) return "API kalit noto'g'ri (HTTP "+(string)http+")";
   if(http==404) return "Model topilmadi (HTTP 404): AZT_Config.ini da model nomini tekshiring";
   if(http==429) return "Limit/balans tugagan (HTTP 429)";
   return "HTTP "+(string)http+(message!="" ? ": "+AZTTrimTo(message,120) : "");
}

// Raw text answer of one provider; false with `error` on failure.
bool AZTAIAsk(const int provider,const string system,const string prompt,const int maxTokens,string &text,string &error) {
   text=""; error="";
   if(!AZTAIHasKey(provider)) { error="no key"; return false; }
   string body, headers, url, host, result;
   int err;
   if(provider==AZT_AI_CLAUDE) {
      host="api.anthropic.com";
      url="https://"+host+"/v1/messages";
      body="{\"model\":\""+AZTJsonEscape(AZTAI_Model[provider])+"\",\"max_tokens\":"+(string)maxTokens+","
           "\"system\":\""+AZTJsonEscape(system)+"\","
           "\"messages\":[{\"role\":\"user\",\"content\":\""+AZTJsonEscape(prompt)+"\"}]}";
      headers="Content-Type: application/json\r\nx-api-key: "+AZTAI_Key[provider]+"\r\nanthropic-version: 2023-06-01\r\n";
   } else {
      host="generativelanguage.googleapis.com";
      url="https://"+host+"/v1beta/models/"+AZTAI_Model[provider]+":generateContent";
      body="{\"systemInstruction\":{\"parts\":[{\"text\":\""+AZTJsonEscape(system)+"\"}]},"
           "\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\""+AZTJsonEscape(prompt)+"\"}]}],"
           "\"generationConfig\":{\"temperature\":0.2,\"responseMimeType\":\"application/json\"}}";
      headers="Content-Type: application/json\r\nx-goog-api-key: "+AZTAI_Key[provider]+"\r\n";
   }
   int http=AZTAIPost(url,headers,body,result,err);
   if(http!=200) { error=AZTAIHttpError(http,err,result,host); return false; }
   string anchor=provider==AZT_AI_CLAUDE ? "\"content\"" : "\"candidates\"";
   text=AZTJsonString(result,"text",MathMax(0,StringFind(result,anchor)));
   if(text=="") { error="Bo'sh javob"; return false; }
   return true;
}

void AZTAIParse(const string text,AZTAIVerdict &verdict) {
   string decision=AZTJsonString(text,"decision");
   StringToUpper(decision);
   verdict.decision=decision=="APPROVE" ? 1 : decision=="REJECT" ? -1 : 0;
   string confidence=AZTJsonToken(text,"confidence");
   verdict.confidence=(int)MathMax(0,MathMin(100,StringToInteger(confidence)));
   verdict.summary=AZTTrimTo(AZTJsonString(text,"summary"),400);
   verdict.risk=AZTTrimTo(AZTJsonString(text,"risk"),200);
   verdict.ok=verdict.decision!=0 && confidence!="";
   if(!verdict.ok) verdict.error="Javobni tushunib bo'lmadi";
}

void AZTAIReview(const int provider,const string prompt,AZTAIVerdict &verdict) {
   ZeroMemory(verdict);
   string text;
   if(!AZTAIAsk(provider,AZT_AI_SYSTEM,prompt,700,text,verdict.error)) return;
   AZTAIParse(text,verdict);
}

// Connection check used by the chart's "AI TEST" button.
string AZTAIPing(const int provider) {
   if(!AZTAIHasKey(provider)) return AZTAIName(provider)+": ❌ kalit yo'q (AZT_Config.ini)";
   AZTAIVerdict verdict;
   AZTAIReview(provider,"CONNECTION TEST, not a trade. Reply REJECT with confidence 0, summary \"test\", risk \"test\".",verdict);
   if(verdict.ok) return AZTAIName(provider)+": ✅ ishlayapti ("+AZTAI_Model[provider]+")";
   return AZTAIName(provider)+": ❌ "+verdict.error+" ("+AZTAI_Model[provider]+")";
}

string AZTAIVerdictText(const string name,const AZTAIVerdict &verdict) {
   if(!verdict.ok) return name+": javob yo'q ("+verdict.error+")";
   return name+": "+(verdict.decision==1 ? "✅ APPROVE" : "⛔ REJECT")+" "+(string)verdict.confidence+"%"+
          (verdict.summary!="" ? "\n  "+verdict.summary : "")+
          (verdict.risk!="" ? "\n  Risk: "+verdict.risk : "");
}

// ---- Lessons: one shared file per provider, newest last ----------------------
string AZTLessonsFile(const int provider) { return "AZT_Lessons_"+AZTAIName(provider)+".txt"; }

int AZTLessonsRead(const int provider,string &lines[]) {
   ArrayResize(lines,0);
   int file=FileOpen(AZTLessonsFile(provider),FILE_READ|FILE_TXT|FILE_SHARE_READ|FILE_ANSI,'\t',CP_UTF8);
   if(file==INVALID_HANDLE) return 0;
   while(!FileIsEnding(file)) {
      string line=FileReadString(file);
      if(StringLen(line)==0) continue;
      int n=ArraySize(lines); ArrayResize(lines,n+1); lines[n]=line;
   }
   FileClose(file);
   return ArraySize(lines);
}

void AZTLessonsAdd(const int provider,const string lesson) {
   string lines[];
   int count=AZTLessonsRead(provider,lines);
   int first=MathMax(0,count-29); // keep the newest 30
   int file=FileOpen(AZTLessonsFile(provider),FILE_WRITE|FILE_TXT|FILE_ANSI,'\t',CP_UTF8);
   if(file==INVALID_HANDLE) return;
   for(int i=first;i<count;i++) FileWrite(file,lines[i]);
   string clean=lesson;
   StringReplace(clean,"\n"," "); StringReplace(clean,"\r"," ");
   FileWrite(file,TimeToString(TimeCurrent(),TIME_DATE)+" "+_Symbol+": "+AZTTrimTo(clean,220));
   FileClose(file);
}

string AZTLessonsText(const int provider,const int newest=12) {
   string lines[];
   int count=AZTLessonsRead(provider,lines);
   string text="";
   for(int i=MathMax(0,count-newest);i<count;i++) text+="\n- "+lines[i];
   return text;
}

// Asks the provider to write itself a lesson about a wrong call; stores it.
bool AZTAIReflect(const int provider,const string facts,string &lesson) {
   lesson="";
   string text, error;
   if(!AZTAIAsk(provider,AZT_AI_REFLECT,facts,300,text,error)) return false;
   lesson=AZTJsonString(text,"lesson");
   if(lesson=="") return false;
   AZTLessonsAdd(provider,lesson);
   return true;
}
#endif
