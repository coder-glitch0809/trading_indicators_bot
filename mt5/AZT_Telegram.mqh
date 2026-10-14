#ifndef AZT_TELEGRAM_MQH
#define AZT_TELEGRAM_MQH
#include "AZT_Json.mqh"

// Native MT5 transport. Credentials live ONLY in MQL5/Files/AZT_Config.ini.
// Call Pump from OnTimer; never enqueue historical/replayed signals.
// API: https://core.telegram.org/bots/api#sendmessage
// MT5: https://www.mql5.com/en/docs/network/webrequest
input group "7. Telegram"
input bool InpTelegramEnabled = true;
input string InpTelegramConfigFile = "AZT_Config.ini"; // MQL5/Files ichida: tokenlar va API kalitlar
input int InpTelegramTimeoutMs = 2500; // Clamped to 500..3000 ms
input bool InpTelegramTestOnStart = false; // Explicit opt-in, persisted once

struct AZTTelegramItem {
   string key;
   string message;
   string photo; // Owned PNG file, deleted when the queue item is removed
   string markup; // Optional reply_markup JSON (inline buttons)
   datetime expires;
   datetime next_try;
   int attempts;
};

AZTTelegramItem AZTTG_Queue[];
string AZTTG_Token="", AZTTG_Chat="", AZTTG_Scope="", AZTTG_Admin="";
string AZTTG_Status="Not initialized";
bool AZTTG_Ready=false;

string AZTTelegramTrim(string value) {
   StringTrimLeft(value); StringTrimRight(value);
   return value;
}

bool AZTTelegramTester() {
   return MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION);
}

string AZTTelegramHash(const string value) {
   // Two independent 32-bit accumulators; only hashes enter filenames/globals.
   uint first=2166136261, second=5381;
   uchar bytes[];
   int size=StringToCharArray(value,bytes,0,WHOLE_ARRAY,CP_UTF8);
   for(int i=0;i<size-1;i++) {
      first=(first^(uint)bytes[i])*16777619;
      second=((second<<5)+second)^(uint)bytes[i];
   }
   return StringFormat("%08X%08X",first,second);
}

string AZTTelegramUrlEncode(const string value) {
   uchar bytes[];
   int size=StringToCharArray(value,bytes,0,WHOLE_ARRAY,CP_UTF8);
   string encoded="", hex="0123456789ABCDEF";
   // StringToCharArray includes a trailing zero; it must not enter the request.
   for(int i=0;i<size-1;i++) {
      int c=(int)bytes[i];
      if((c>=65 && c<=90) || (c>=97 && c<=122) || (c>=48 && c<=57) ||
         c==45 || c==46 || c==95 || c==126)
         encoded+=CharToString((uchar)c);
      else encoded+="%"+StringSubstr(hex,c/16,1)+StringSubstr(hex,c%16,1);
   }
   return encoded;
}

string AZTTelegramJsonScalar(const string json,const string key) {
   // Walk JSON strings (including escapes), so text inside messages cannot be
   // mistaken for response fields. Only simple API scalars are needed here.
   int length=StringLen(json);
   for(int i=0;i<length;i++) {
      if(StringGetCharacter(json,i)!=34) continue;
      int start=++i;
      while(i<length) {
         ushort c=StringGetCharacter(json,i);
         if(c==92) { i+=2; continue; }
         if(c==34) break;
         i++;
      }
      if(i>=length) return "";
      string found=StringSubstr(json,start,i-start);
      int at=i+1;
      while(at<length && StringGetCharacter(json,at)<=32) at++;
      if(found!=key || at>=length || StringGetCharacter(json,at)!=58) continue;
      at++;
      while(at<length && StringGetCharacter(json,at)<=32) at++;
      int end=at;
      while(end<length) {
         ushort c=StringGetCharacter(json,end);
         if(c==44 || c==125 || c==93 || c<=32) break;
         end++;
      }
      return StringSubstr(json,at,end-at);
   }
   return "";
}

bool AZTTelegramValidToken(const string value) {
   int colon=StringFind(value,":");
   if(colon<1 || colon>=StringLen(value)-20) return false;
   for(int i=0;i<StringLen(value);i++) {
      ushort c=StringGetCharacter(value,i);
      if(i==colon) continue;
      if(c>=48 && c<=57) continue;
      if(i<colon) return false;
      if((c>=65 && c<=90) || (c>=97 && c<=122) || c==45 || c==95) continue;
      return false;
   }
   return true;
}

bool AZTTelegramValidChat(const string value) {
   int length=StringLen(value);
   if(length==0) return false;
   bool username=StringGetCharacter(value,0)==64;
   int start=(username || StringGetCharacter(value,0)==45) ? 1 : 0;
   if(start==length) return false;
   for(int i=start;i<length;i++) {
      ushort c=StringGetCharacter(value,i);
      if(c>=48 && c<=57) continue;
      if(username && ((c>=65 && c<=90) || (c>=97 && c<=122) || c==95)) continue;
      return false;
   }
   return true;
}

void AZTTelegramReadConfig(string &token,string &chat,const string wanted,string &found) {
   int file=FileOpen(InpTelegramConfigFile,FILE_READ|FILE_TXT|FILE_ANSI,'\t',CP_UTF8);
   if(file==INVALID_HANDLE) return;
   while(!FileIsEnding(file)) {
      string line=AZTTelegramTrim(FileReadString(file));
      if(StringLen(line)>0 && StringGetCharacter(line,0)==65279)
         line=StringSubstr(line,1);
      if(line=="" || StringSubstr(line,0,1)=="#" || StringSubstr(line,0,1)==";") continue;
      int separator=StringFind(line,"=");
      if(separator<1) continue;
      string name=AZTTelegramTrim(StringSubstr(line,0,separator));
      string value=AZTTelegramTrim(StringSubstr(line,separator+1));
      int length=StringLen(value);
      if(length>=2 && ((StringSubstr(value,0,1)=="\"" && StringSubstr(value,length-1)=="\"") ||
                      (StringSubstr(value,0,1)=="'" && StringSubstr(value,length-1)=="'")))
         value=StringSubstr(value,1,length-2);
      if(name=="TELEGRAM_BOT_TOKEN" || name=="BOT_TOKEN") token=value;
      if(name=="TELEGRAM_CHAT_ID" || name=="CHAT_ID") chat=value;
      if(wanted!="" && name==wanted) found=value;
   }
   FileClose(file);
}

void AZTTelegramReadConfig(string &token,string &chat) {
   string unused="";
   AZTTelegramReadConfig(token,chat,"",unused);
}

// Reads NAME=value from the private INI in MQL5/Files ("" when absent).
string AZTConfigValue(const string wanted) {
   string token="",chat="",found="";
   AZTTelegramReadConfig(token,chat,wanted,found);
   return found;
}

string AZTTelegramMarker(const string key) {
   return "AZTTG."+AZTTG_Scope+"."+AZTTelegramHash(key);
}

void AZTTelegramRemove(const int index) {
   if(AZTTG_Queue[index].photo!="") FileDelete(AZTTG_Queue[index].photo);
   int count=ArraySize(AZTTG_Queue);
   for(int i=index;i<count-1;i++) AZTTG_Queue[i]=AZTTG_Queue[i+1];
   ArrayResize(AZTTG_Queue,count-1);
}

bool AZTTelegramQueue(const string stable_key,const string message,const int expiry_seconds=180,const string markup="") {
   if(AZTTelegramTester()) { AZTTG_Status="Disabled in Strategy Tester"; return false; }
   if(!AZTTG_Ready || stable_key=="" || message=="") return false;
   if(StringLen(message)>4096) { AZTTG_Status="Message exceeds Telegram limit"; return false; }
   string marker=AZTTelegramMarker(stable_key);
   if(GlobalVariableCheck(marker)) return false;
   int count=ArraySize(AZTTG_Queue);
   for(int i=0;i<count;i++) if(AZTTG_Queue[i].key==stable_key) return false;
   if(count>=8) { AZTTG_Status="Queue full; newest signal skipped"; return false; }
   ArrayResize(AZTTG_Queue,count+1);
   AZTTG_Queue[count].photo="";
   AZTTG_Queue[count].key=stable_key;
   AZTTG_Queue[count].message=message;
   AZTTG_Queue[count].markup=markup;
   AZTTG_Queue[count].expires=TimeLocal()+MathMax(1,MathMin(expiry_seconds,300));
   AZTTG_Queue[count].next_try=0;
   AZTTG_Queue[count].attempts=0;
   AZTTG_Status="Queued ("+(string)(count+1)+")";
   return true;
}

bool AZTTelegramRequestTest() {
   const string key="connection-test-v1";
   if(AZTTG_Ready && GlobalVariableCheck(AZTTelegramMarker(key))) {
      AZTTG_Status="Test already sent/attempted; duplicate suppressed";
      return false;
   }
   return AZTTelegramQueue(key,
      "AZT MT5 — TEST XABARI\nTelegram aloqasi ishlayapti.\nBu savdo signali emas; order ochilmaydi.\n"
      "Manba: MetaTrader 5\n"+_Symbol+" | "+TimeToString(TimeLocal(),TIME_DATE|TIME_SECONDS),120);
}

bool AZTTelegramInit() {
   AZTTG_Ready=false;
   AZTTG_Token=""; AZTTG_Chat=""; AZTTG_Scope=""; AZTTG_Admin="";
   ArrayResize(AZTTG_Queue,0);
   if(AZTTelegramTester()) { AZTTG_Status="Disabled in Strategy Tester"; return true; }
   if(!InpTelegramEnabled) { AZTTG_Status="OFF (signals remain local)"; return true; }
   AZTTelegramReadConfig(AZTTG_Token,AZTTG_Chat,"TELEGRAM_ADMIN_ID",AZTTG_Admin);
   if(!AZTTelegramValidToken(AZTTG_Token) || !AZTTelegramValidChat(AZTTG_Chat)) {
      AZTTG_Status="Missing/invalid credentials: MQL5/Files/"+InpTelegramConfigFile;
      return false;
   }
   // Scope to bot ID + recipient; changing a token does not resend old signals.
   AZTTG_Scope=AZTTelegramHash(StringSubstr(AZTTG_Token,0,StringFind(AZTTG_Token,":"))+"|"+AZTTG_Chat);
   AZTTG_Ready=true;
   AZTTG_Status="Ready; allow https://api.telegram.org in MT5 WebRequest";
   if(InpTelegramTestOnStart) AZTTelegramRequestTest();
   return true;
}

string AZTTelegramStatus() { return AZTTG_Status; }

bool AZTTelegramReady() { return AZTTG_Ready && !AZTTelegramTester(); }

int AZTTelegramLock() {
   return FileOpen("AZT_Telegram_"+AZTTG_Scope+".lock",FILE_READ|FILE_WRITE|FILE_BIN);
}

// ---- Trade approval buttons -------------------------------------------------
// callback_data is "AZT|Y|<id>" or "AZT|N|<id>". Whichever chart polls stores the
// decision in terminal global "AZTDEC.<id>" (1 approve, -1 reject) and the chart
// owning <id> reads it, so several charts can share one bot.

string AZTApprovalMarkup(const string id) {
   return "{\"inline_keyboard\":[[{\"text\":\"✅ KIRISH\",\"callback_data\":\"AZT|Y|"+id+"\"},"
          "{\"text\":\"❌ BEKOR\",\"callback_data\":\"AZT|N|"+id+"\"}]]}";
}

string AZTDecisionName(const string id) { return "AZTDEC."+id; }

// 1 approved, -1 rejected, 0 no answer yet.
int AZTDecision(const string id) {
   string name=AZTDecisionName(id);
   if(!GlobalVariableCheck(name)) return 0;
   double value=GlobalVariableGet(name);
   return value>0 ? 1 : value<0 ? -1 : 0;
}

int AZTTelegramPost(const string method,const string body,string &result,int &error) {
   char request[],response[];
   int bytes=StringToCharArray(body,request,0,WHOLE_ARRAY,CP_UTF8);
   ArrayResize(request,MathMax(0,bytes-1));
   string response_headers;
   ResetLastError();
   int http=WebRequest("POST","https://api.telegram.org/bot"+AZTTG_Token+"/"+method,
      "Content-Type: application/x-www-form-urlencoded\r\n",
      MathMax(500,MathMin(InpTelegramTimeoutMs,3000)),request,response,response_headers);
   error=GetLastError();
   result=CharArrayToString(response,0,WHOLE_ARRAY,CP_UTF8);
   return http;
}

// True when the press came from the configured chat (and TELEGRAM_ADMIN_ID, if set).
bool AZTTelegramAuthorised(const string update) {
   int chat=AZTJsonValueAt(update,"chat");
   if(chat<0) return false;
   bool chatOk=AZTJsonToken(update,"id",chat)==AZTTG_Chat;
   if(!chatOk && StringGetCharacter(AZTTG_Chat,0)==64)
      chatOk=("@"+AZTJsonString(update,"username",chat))==AZTTG_Chat;
   if(!chatOk) return false;
   if(AZTTG_Admin=="") return true;
   int from=AZTJsonValueAt(update,"from");
   return from>=0 && AZTJsonToken(update,"id",from)==AZTTG_Admin;
}

// Short-polls getUpdates for button presses. Call from OnTimer while waiting.
void AZTTelegramPollDecisions() {
   if(AZTTelegramTester() || !AZTTG_Ready) return;
   int lock=AZTTelegramLock();
   if(lock==INVALID_HANDLE) return;
   string offsetName="AZTTG.offset."+AZTTG_Scope;
   long offset=GlobalVariableCheck(offsetName) ? (long)GlobalVariableGet(offsetName) : 0;
   string result; int error;
   int http=AZTTelegramPost("getUpdates","timeout=0&limit=50&offset="+(string)offset+
      "&allowed_updates="+AZTTelegramUrlEncode("[\"callback_query\"]"),result,error);
   if(http==409) {
      AZTTG_Status="getUpdates 409: bot has a webhook; call deleteWebhook once";
      FileClose(lock); return;
   }
   if(http!=200 || AZTJsonToken(result,"ok")!="true") {
      if(http==-1 && error==4014) AZTTG_Status="Allow https://api.telegram.org: Tools > Options > Expert Advisors";
      FileClose(lock); return;
   }
   long next=offset;
   int at=StringFind(result,"\"update_id\"");
   while(at>=0) {
      int following=StringFind(result,"\"update_id\"",at+1);
      string update=following>0 ? StringSubstr(result,at,following-at) : StringSubstr(result,at);
      long updateId=StringToInteger(AZTJsonToken(update,"update_id"));
      if(updateId>=next) next=updateId+1;
      int callback=AZTJsonValueAt(update,"callback_query");
      string data=callback>=0 ? AZTJsonString(update,"data",callback) : "";
      if(StringSubstr(data,0,4)=="AZT|" && StringLen(data)>6) {
         string id=StringSubstr(data,6), answer;
         if(!AZTTelegramAuthorised(update)) answer="Ruxsat yo'q";
         else if(GlobalVariableCheck(AZTDecisionName(id))) answer="Qaror allaqachon qabul qilingan";
         else {
            bool approve=StringSubstr(data,4,1)=="Y";
            GlobalVariableSet(AZTDecisionName(id),approve ? 1.0 : -1.0);
            answer=approve ? "Tasdiqlandi: EA tekshirib savdoga kiradi" : "Bekor qilindi";
         }
         string callbackId=AZTJsonString(update,"id",callback), ignored; int ignoredError;
         if(callbackId!="")
            AZTTelegramPost("answerCallbackQuery","callback_query_id="+AZTTelegramUrlEncode(callbackId)+
               "&text="+AZTTelegramUrlEncode(answer),ignored,ignoredError);
      }
      at=following;
   }
   if(next!=offset) GlobalVariableSet(offsetName,(double)next);
   GlobalVariablesFlush();
   FileClose(lock);
}

// Multipart encoding keeps binary PNG bytes intact (no URL encoding).
void AZTTGAppend(char &target[],const string value) {
   char bytes[]; int n=StringToCharArray(value,bytes,0,WHOLE_ARRAY,CP_UTF8)-1;
   int at=ArraySize(target); ArrayResize(target,at+n); ArrayCopy(target,bytes,at,0,n);
}
bool AZTTGPhotoBody(const AZTTelegramItem &item,char &body[],string &headers) {
   int file=FileOpen(item.photo,FILE_READ|FILE_BIN);
   if(file==INVALID_HANDLE) return false;
   long size=(long)FileSize(file);
   if(size<1 || size>10000000) { FileClose(file); return false; }
   char png[]; ArrayResize(png,(int)size);
   uint read=FileReadArray(file,png,0,(int)size); FileClose(file);
   if(read!=(uint)size) return false;
   string boundary="AZT"+AZTTelegramHash(item.key);
   ArrayResize(body,0);
   AZTTGAppend(body,"--"+boundary+"\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n"+AZTTG_Chat+"\r\n");
   AZTTGAppend(body,"--"+boundary+"\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n"+item.message+"\r\n");
   AZTTGAppend(body,"--"+boundary+"\r\nContent-Disposition: form-data; name=\"photo\"; filename=\"signal.png\"\r\nContent-Type: image/png\r\n\r\n");
   int at=ArraySize(body); ArrayResize(body,at+(int)size); ArrayCopy(body,png,at,0,(int)size);
   AZTTGAppend(body,"\r\n--"+boundary+"--\r\n");
   headers="Content-Type: multipart/form-data; boundary="+boundary+"\r\n";
   return true;
}
bool AZTTelegramQueuePhoto(const string key,const string caption,const string filename) {
   if(StringLen(caption)>1024 || !AZTTelegramQueue(key,caption,180)) return false;
   int i=ArraySize(AZTTG_Queue)-1;
   AZTTG_Queue[i].photo=filename;
   AZTTG_Queue[i].next_try=TimeLocal()+2; // ChartScreenShot is processed by the chart queue.
   return true;
}

void AZTTelegramPump() {
   if(AZTTelegramTester() || !AZTTG_Ready) return;
   datetime now=TimeLocal();
   for(int i=ArraySize(AZTTG_Queue)-1;i>=0;i--) {
      if(AZTTG_Queue[i].expires<=now) {
         AZTTelegramRemove(i);
         AZTTG_Status="Expired signal dropped; waiting for a fresh setup";
      }
   }
   if(ArraySize(AZTTG_Queue)==0 || AZTTG_Queue[0].next_try>now) return;

   // Denying file sharing gives a nonblocking cross-chart lock. Keep it held
   // through the one bounded request so no chart races the durable marker.
   int lock=AZTTelegramLock();
   if(lock==INVALID_HANDLE) return;
   string pace="AZTTG.next."+AZTTG_Scope;
   if(GlobalVariableCheck(pace) && GlobalVariableGet(pace)>(double)now) {
      FileClose(lock); return;
   }
   string marker=AZTTelegramMarker(AZTTG_Queue[0].key);
   if(GlobalVariableCheck(marker)) {
      AZTTelegramRemove(0); FileClose(lock); return;
   }
   // Telegram has no idempotency key. Persist an attempt BEFORE I/O so a crash
   // or ambiguous timeout never creates a duplicate notification on restart.
   ResetLastError();
   if(GlobalVariableSet(marker,-(double)now)==0) {
      AZTTG_Status="Cannot persist notification marker; send paused";
      FileClose(lock); return;
   }
   GlobalVariablesFlush();

   string body="chat_id="+AZTTelegramUrlEncode(AZTTG_Chat)+
               "&text="+AZTTelegramUrlEncode(AZTTG_Queue[0].message);
   if(AZTTG_Queue[0].markup!="") body+="&reply_markup="+AZTTelegramUrlEncode(AZTTG_Queue[0].markup);
   char request[],response[];
   int bytes=StringToCharArray(body,request,0,WHOLE_ARRAY,CP_UTF8);
   ArrayResize(request,bytes-1); // Exact body bytes; exclude the trailing NUL.
   string headers="Content-Type: application/x-www-form-urlencoded\r\n", method="sendMessage";
   if(AZTTG_Queue[0].photo!="") {
      if(!AZTTGPhotoBody(AZTTG_Queue[0],request,headers)) {
         GlobalVariableDel(marker);
         AZTTG_Status="Signal PNG unavailable; text follows";
         AZTTelegramRemove(0); FileClose(lock); return;
      }
      method="sendPhoto";
   }
   string response_headers;
   int timeout=MathMax(500,MathMin(InpTelegramTimeoutMs,3000));
   AZTTG_Queue[0].attempts++;
   ResetLastError();
   int http=WebRequest("POST","https://api.telegram.org/bot"+AZTTG_Token+"/"+method,
      headers,timeout,request,response,response_headers);
   int error=GetLastError();
   string result=CharArrayToString(response,0,WHOLE_ARRAY,CP_UTF8);
   string ok=AZTTelegramJsonScalar(result,"ok");
   now=TimeLocal();
   GlobalVariableSet(pace,(double)(now+1));
   if(http==200 && ok=="true") {
      GlobalVariableSet(marker,(double)now);
      GlobalVariablesFlush();
      AZTTG_Status="Sent "+TimeToString(now,TIME_SECONDS)+" (Telegram confirmed)";
      AZTTelegramRemove(0);
   } else if(ok=="false" && (http==429 || http>=500)) {
      // A definite API rejection can be retried. Never replay an old signal.
      GlobalVariableDel(marker);
      int delay=5*AZTTG_Queue[0].attempts;
      if(http==429) {
         long retry=StringToInteger(AZTTelegramJsonScalar(result,"retry_after"));
         delay=(int)MathMax(1,MathMin(retry>0 ? retry : 30,86400));
      }
      GlobalVariableSet(pace,(double)(now+delay));
      AZTTG_Queue[0].next_try=now+delay;
      if(AZTTG_Queue[0].attempts>=3 || AZTTG_Queue[0].next_try>=AZTTG_Queue[0].expires) {
         AZTTG_Status="HTTP "+(string)http+"; retry limit/expiry reached";
         AZTTelegramRemove(0);
      } else AZTTG_Status="HTTP "+(string)http+"; retry in "+(string)delay+" s";
      GlobalVariablesFlush();
   } else {
      bool definitely_rejected=(ok=="false" || (http==-1 && (error==4014 || error==5200)));
      if(definitely_rejected) GlobalVariableDel(marker);
      if(http==-1 && error==4014)
         AZTTG_Status="Allow https://api.telegram.org: Tools > Options > Expert Advisors";
      else if(http==401) AZTTG_Status="Telegram rejected bot token (HTTP 401)";
      else if(http==400) AZTTG_Status="Check chat ID; open bot and press Start (HTTP 400)";
      else if(http==403) AZTTG_Status="Bot blocked/no chat permission (HTTP 403)";
      else if(definitely_rejected) AZTTG_Status="Telegram rejected request; HTTP "+(string)http+" / MT5 "+(string)error;
      else AZTTG_Status="Delivery unknown; not retried to prevent duplicates (HTTP "+(string)http+" / MT5 "+(string)error+")";
      // Never print response body, full URL, token, or chat ID.
      GlobalVariablesFlush();
      AZTTelegramRemove(0);
   }
   FileClose(lock);
}

#endif
