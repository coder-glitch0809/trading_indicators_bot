// Offline transport tests. The production WebRequest call is replaced at
// compile time, so running this script cannot contact Telegram or open trades.
#property strict
int FakeHTTP=200, FakeError=0, FakeCalls=0;
string FakeBody="{\"ok\":true,\"result\":{\"message_id\":1}}", FakePayload="";
int FakeTimeout=0;
int AZTTestWebRequest(const string method,const string url,const string headers,
                     const int timeout,const char &data[],char &response[],string &response_headers) {
   FakeCalls++;
   FakePayload=CharArrayToString(data,0,WHOLE_ARRAY,CP_UTF8);
   FakeTimeout=timeout;
   if(ArraySize(data)>0 && data[ArraySize(data)-1]==0) FakePayload="TRAILING_NUL";
   StringToCharArray(FakeBody,response,0,WHOLE_ARRAY,CP_UTF8);
   response_headers="Content-Type: application/json";
   if(FakeError!=0) SetUserError((ushort)FakeError);
   return FakeHTTP;
}
#define WebRequest AZTTestWebRequest
#include "../mt5/AZT_Telegram.mqh"
#include "../mt5/AZT_AI.mqh"
#undef WebRequest

int Passed=0,Failed=0;
void Check(const bool ok,const string name) {
   if(ok) { Passed++; Print("PASS: ",name); }
   else { Failed++; Print("FAIL: ",name); }
}
void ClearTestState() {
   string keys[]={"one","retry","timeout","expired","denied","connection-test-v1"};
   for(int i=0;i<ArraySize(keys);i++) GlobalVariableDel(AZTTelegramMarker(keys[i]));
   GlobalVariableDel("AZTTG.next."+AZTTG_Scope);
}
void Fixture() {
   AZTTG_Scope="UNIT_"+(string)ChartID();
   ClearTestState();
   AZTTG_Token="123456:OfflineFakeTokenNeverSentToNetwork";
   AZTTG_Chat="-1234567890";
   AZTTG_Ready=true;
   ArrayResize(AZTTG_Queue,0);
   FakeHTTP=200; FakeError=0; FakeCalls=0;
   FakeBody="{\"ok\":true,\"result\":{\"message_id\":1}}";
   FakePayload="";
}
void OnStart() {
   Check(AZTTelegramUrlEncode("a b&c=+%") == "a%20b%26c%3D%2B%25","form reserved characters encoded");
   Check(AZTTelegramUrlEncode("O‘zbek 🇺🇿") == "O%E2%80%98zbek%20%F0%9F%87%BA%F0%9F%87%BF","UTF8 non-ASCII and emoji bytes encoded");
   Check(AZTTelegramUrlEncode("abc-_.~09")=="abc-_.~09","unreserved ASCII unchanged without trailing NUL");
   Check(AZTTelegramJsonScalar("{\"ok\" : false,\"parameters\":{\"retry_after\":7}}","retry_after")=="7","nested retry_after parsed");
   Check(AZTTelegramJsonScalar("{\"text\":\"escaped \\\"ok\\\":false\",\"ok\":true}","ok")=="true","quoted text cannot spoof API status");
   Check(AZTTelegramValidToken("123:abcdefghijklmnopqrstuvwxyz_0123-"),"valid token accepted");
   Check(!AZTTelegramValidToken("123:abcdefghijklmnopqrstuvwxyz/path"),"token URL injection rejected");
   Check(AZTTelegramValidChat("-1001234567890") && AZTTelegramValidChat("@sample_channel"),"numeric group and channel chat accepted");
   Check(!AZTTelegramValidChat("123&text=bad"),"invalid chat rejected");
   Check(AZTTelegramHash("a")!=AZTTelegramHash("b") && AZTTelegramHash("a")==AZTTelegramHash("a"),"keys hashed deterministically");

   Fixture();
   Check(AZTTelegramQueue("one","TEST & text"),"fresh message queued");
   Check(!AZTTelegramQueue("one","duplicate"),"queued duplicate suppressed");
   AZTTelegramPump();
   Check(FakeCalls==1 && ArraySize(AZTTG_Queue)==0,"successful request removed from queue");
   Check(FakePayload=="chat_id=-1234567890&text=TEST%20%26%20text","exact encoded request body without NUL");
   Check(FakeTimeout<=3000 && FakeTimeout>=500,"transport call timeout bounded");
   Check(GlobalVariableGet(AZTTelegramMarker("one"))>0,"success persisted across EA restart");
   Check(!AZTTelegramQueue("one","duplicate"),"persisted duplicate suppressed");

   Fixture(); FakeHTTP=429; FakeBody="{\"ok\":false,\"parameters\":{\"retry_after\":9}}";
   AZTTelegramQueue("retry","retry test"); AZTTelegramPump();
   Check(FakeCalls==1 && ArraySize(AZTTG_Queue)==1 && AZTTG_Queue[0].attempts==1,"definite rate rejection retained for retry");
   Check(AZTTG_Queue[0].next_try>=TimeLocal()+8 && !GlobalVariableCheck(AZTTelegramMarker("retry")),"retry_after respected and failed marker released");
   AZTTelegramPump(); Check(FakeCalls==1,"no busy/blocking retry before deadline");
   for(int i=0;i<2;i++) {
      AZTTG_Queue[0].next_try=0; GlobalVariableDel("AZTTG.next."+AZTTG_Scope);
      AZTTelegramPump();
   }
   Check(FakeCalls==3 && ArraySize(AZTTG_Queue)==0,"maximum three attempts enforced");

   Fixture(); FakeHTTP=-1; FakeBody="";
   AZTTelegramQueue("timeout","uncertain test"); AZTTelegramPump(); AZTTelegramPump();
   Check(FakeCalls==1 && ArraySize(AZTTG_Queue)==0,"ambiguous network failure never replayed");
   Check(GlobalVariableGet(AZTTelegramMarker("timeout"))<0 && !AZTTelegramQueue("timeout","again"),"ambiguous attempt persisted against restart duplicates");

   Fixture(); FakeHTTP=403; FakeBody="{\"ok\":false,\"error_code\":403}";
   AZTTelegramQueue("denied","permission test"); AZTTelegramPump();
   Check(FakeCalls==1 && ArraySize(AZTTG_Queue)==0 && !GlobalVariableCheck(AZTTelegramMarker("denied")),"permanent API rejection dropped without retry");

   Fixture();
   AZTTelegramQueue("expired","old setup"); AZTTG_Queue[0].expires=TimeLocal()-1;
   AZTTelegramPump();
   Check(FakeCalls==0 && ArraySize(AZTTG_Queue)==0,"expired signal never sent");
   Check(AZTTelegramRequestTest(),"explicit test queued"); AZTTelegramPump();
   Check(FakeCalls==1 && !AZTTelegramRequestTest(),"explicit test sent once across repeated triggers");

   // Binary multipart upload and owned-file cleanup, no external requests.
   Fixture();
   string photo="azt_test_photo.png";
   int pf=FileOpen(photo,FILE_WRITE|FILE_BIN);
   uchar raw[]={137,80,78,71,0,13,10,255}; FileWriteArray(pf,raw); FileClose(pf);
   Check(AZTTelegramQueuePhoto("photo-test","BUY EURUSD",photo),"photo queued");
   char multipart[]; string headers;
   Check(AZTTGPhotoBody(AZTTG_Queue[0],multipart,headers) && StringFind(headers,"multipart/form-data")>=0,"multipart PNG body built");
   string encoded=CharArrayToString(multipart,0,WHOLE_ARRAY,CP_UTF8);
   Check(StringFind(encoded,"name=\"caption\"")>=0 && StringFind(encoded,"filename=\"signal.png\"")>=0,"photo fields have caption and filename");
   AZTTG_Queue[0].next_try=0; AZTTelegramPump();
   Check(FakeCalls==1 && ArraySize(AZTTG_Queue)==0 && !FileIsExist(photo),"photo sent and file cleaned");

   // JSON helpers and AI verdict parsing.
   Check(AZTJsonString("{\"a\":\"x \\\"q\\\" \\u0041\\n\"}","a")=="x \"q\" A\n","JSON string escapes decoded");
   Check(AZTJsonEscape("a\"b\\c\nd")=="a\\\"b\\\\c\\nd","JSON string escaped");
   AZTAIVerdict verdict;
   AZTAIParse("```json\n{\"decision\":\"approve\",\"confidence\":82,\"summary\":\"Trend bir xil\",\"risk\":\"Yangilik\"}\n```",verdict);
   Check(verdict.ok && verdict.decision==1 && verdict.confidence==82 && verdict.summary=="Trend bir xil","AI APPROVE verdict parsed from fenced text");
   AZTAIParse("{\"decision\":\"REJECT\",\"confidence\":140}",verdict);
   Check(verdict.ok && verdict.decision==-1 && verdict.confidence==100,"AI REJECT parsed and confidence clamped");
   AZTAIParse("I think it's fine",verdict);
   Check(!verdict.ok,"free text is not treated as approval");

   // Lessons file keeps the newest entries for each provider.
   FileDelete(AZTLessonsFile(AZT_AI_CLAUDE));
   for(int i=0;i<35;i++) AZTLessonsAdd(AZT_AI_CLAUDE,"lesson "+(string)i+"\nline");
   string lessons[];
   Check(AZTLessonsRead(AZT_AI_CLAUDE,lessons)==30 && StringFind(lessons[29],"lesson 34 line")>0,"lessons capped at newest 30, one line each");
   Check(StringFind(AZTLessonsText(AZT_AI_CLAUDE,3),"lesson 32")>0 && StringFind(AZTLessonsText(AZT_AI_CLAUDE,3),"lesson 31")<0,"prompt shows newest lessons");
   FileDelete(AZTLessonsFile(AZT_AI_CLAUDE));

   // Approval buttons and getUpdates polling.
   Fixture();
   AZTTelegramQueue("approve-msg","Tasdiqlaysizmi?",180,AZTApprovalMarkup("ABC"));
   AZTTelegramPump();
   Check(StringFind(FakePayload,"&reply_markup=%7B%22inline_keyboard%22")>0,"approval buttons sent as reply_markup");
   GlobalVariableDel(AZTDecisionName("ABC")); GlobalVariableDel(AZTDecisionName("XYZ"));
   GlobalVariableDel("AZTTG.offset."+AZTTG_Scope);
   FakeBody="{\"ok\":true,\"result\":[{\"update_id\":500,\"callback_query\":{\"id\":\"cb1\",\"from\":{\"id\":42},"
            "\"message\":{\"message_id\":7,\"chat\":{\"id\":-1234567890,\"type\":\"group\"},\"text\":\"x\"},\"data\":\"AZT|Y|ABC\"}},"
            "{\"update_id\":501,\"callback_query\":{\"id\":\"cb2\",\"from\":{\"id\":9},"
            "\"message\":{\"message_id\":8,\"chat\":{\"id\":555,\"type\":\"private\"},\"text\":\"x\"},\"data\":\"AZT|Y|XYZ\"}}]}";
   AZTTelegramPollDecisions();
   Check(AZTDecision("ABC")==1,"button press from configured chat approves");
   Check(AZTDecision("XYZ")==0,"button press from another chat ignored");
   Check(GlobalVariableGet("AZTTG.offset."+AZTTG_Scope)==502,"getUpdates offset advanced past handled updates");
   AZTTG_Admin="7";
   GlobalVariableDel(AZTDecisionName("ABC"));
   FakeBody=StringSubstr(FakeBody,0,StringFind(FakeBody,",{\"update_id\":501"))+"]}";
   AZTTelegramPollDecisions();
   Check(AZTDecision("ABC")==0,"TELEGRAM_ADMIN_ID blocks other group members");
   AZTTG_Admin="";
   StringReplace(FakeBody,"AZT|Y|ABC","AZT|N|ABC");
   AZTTelegramPollDecisions();
   Check(AZTDecision("ABC")==-1,"reject button stores rejection");
   GlobalVariableDel(AZTDecisionName("ABC")); GlobalVariableDel(AZTDecisionName("XYZ"));
   GlobalVariableDel("AZTTG.offset."+AZTTG_Scope);
   GlobalVariableDel(AZTTelegramMarker("approve-msg"));
   ClearTestState();
   FileDelete("AZT_Telegram_"+AZTTG_Scope+".lock");
   string report="AZT_TELEGRAM_TEST_RESULT passed="+(string)Passed+" failed="+(string)Failed;
   Print(report);
   int file=FileOpen("azt_telegram_test_result.txt",FILE_WRITE|FILE_TXT);
   if(file!=INVALID_HANDLE) { FileWrite(file,report); FileClose(file); }
}
