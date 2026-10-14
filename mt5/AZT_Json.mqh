#ifndef AZT_JSON_MQH
#define AZT_JSON_MQH
// Minimal JSON helpers for Telegram / Claude responses.
// Not a general parser: finds "key": value pairs, decoding string escapes.

string AZTJsonEscape(const string value) {
   string out="";
   int length=StringLen(value);
   for(int i=0;i<length;i++) {
      ushort c=StringGetCharacter(value,i);
      if(c==34) out+="\\\"";
      else if(c==92) out+="\\\\";
      else if(c==10) out+="\\n";
      else if(c==13) out+="\\r";
      else if(c==9) out+="\\t";
      else if(c<32) out+=StringFormat("\\u%04X",c);
      else out+=ShortToString(c);
   }
   return out;
}

int AZTJsonHex(const ushort c) {
   if(c>=48 && c<=57) return c-48;
   if(c>=65 && c<=70) return c-55;
   if(c>=97 && c<=102) return c-87;
   return -1;
}

// Position just after `"key":` (whitespace skipped), or -1.
int AZTJsonValueAt(const string json,const string key,const int from=0) {
   string needle="\""+key+"\"";
   int length=StringLen(json);
   int at=StringFind(json,needle,from);
   while(at>=0) {
      int i=at+StringLen(needle);
      while(i<length && StringGetCharacter(json,i)<=32) i++;
      if(i<length && StringGetCharacter(json,i)==58) {
         i++;
         while(i<length && StringGetCharacter(json,i)<=32) i++;
         return i;
      }
      at=StringFind(json,needle,at+1);
   }
   return -1;
}

// Decodes the string value of `key`; "" when absent or not a string.
string AZTJsonString(const string json,const string key,const int from=0) {
   int i=AZTJsonValueAt(json,key,from);
   int length=StringLen(json);
   if(i<0 || i>=length || StringGetCharacter(json,i)!=34) return "";
   string out="";
   for(i++;i<length;i++) {
      ushort c=StringGetCharacter(json,i);
      if(c==34) return out;
      if(c!=92) { out+=ShortToString(c); continue; }
      if(++i>=length) break;
      c=StringGetCharacter(json,i);
      if(c==110) out+="\n";
      else if(c==116) out+="\t";
      else if(c==114) out+="\r";
      else if(c==98 || c==102) continue;
      else if(c==117 && i+4<length) {
         int code=0;
         for(int k=1;k<=4;k++) {
            int h=AZTJsonHex(StringGetCharacter(json,i+k));
            if(h<0) { code=-1; break; }
            code=code*16+h;
         }
         if(code>=0) { out+=ShortToString((ushort)code); i+=4; }
      }
      else out+=ShortToString(c); // \" \\ \/
   }
   return out;
}

// Raw scalar token (number, true/false/null) of `key`; "" when absent.
string AZTJsonToken(const string json,const string key,const int from=0) {
   int i=AZTJsonValueAt(json,key,from);
   if(i<0) return "";
   int end=i, length=StringLen(json);
   while(end<length) {
      ushort c=StringGetCharacter(json,end);
      if(c==44 || c==125 || c==93 || c<=32) break;
      end++;
   }
   string token=StringSubstr(json,i,end-i);
   StringReplace(token,"\"","");
   return token;
}

string AZTTrimTo(const string value,const int limit) {
   if(StringLen(value)<=limit) return value;
   return StringSubstr(value,0,limit-1)+"…";
}
#endif
