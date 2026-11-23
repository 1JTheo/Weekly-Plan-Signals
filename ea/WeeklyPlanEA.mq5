//+------------------------------------------------------------------+
//|                                                 WeeklyPlanEA.mq5 |
//|  Reads the weekly plan file Claude publishes to GitHub and       |
//|  trades it: scenario tracks, calendar-driven switching, 30-min   |
//|  order-block entries, risk caps, news blackout and tripwires.    |
//|  Attach to ONE chart. It trades every symbol named in the plan.  |
//+------------------------------------------------------------------+
#property copyright   "Joseph x Claude"
#property version     "1.00"
#property description "Executes the weekly plan file. Settings: plan URL, auto-trade switch, magic number."

#include <Trade\Trade.mqh>

//--- the only three settings
input string InpPlanURL   = "https://raw.githubusercontent.com/1JTheo/Weekly-Plan-Signals/main/weekly_plan.txt";
input bool   InpAutoTrade = true;     // false = watch and alert only, no orders
input long   InpMagic     = 482026;

//--- fixed behaviour (deliberately not settings)
#define TIMER_SEC        15
#define POLL_SEC         300      // download the plan every 5 minutes
#define PENDING_HOURS    8        // cancel an unfilled order-block limit after 8h
#define OB_LOOKBACK      45       // M30 bars searched for an order block
#define SL_BUFFER_ATR    0.25     // stop buffer beyond the order block, x ATR(M30,14)
#define MIN_RR           1.5      // minimum reward:risk to tp2
#define RETRY_SEC        300

//--- states
#define ST_IDLE    0
#define ST_ARMED   1
#define ST_PENDING 2
#define ST_OPEN    3
#define ST_DONE    4
#define ST_DEAD    5

struct SSetup
  {
   string            id, track, scen, sym, bsym, trig, grp;
   int               dir;               // +1 buy, -1 sell
   double            lvl, zlo, zhi, inv, tp1, tp2, rm;
   ENUM_TIMEFRAMES   invtf;
   int               hold, window;      // hours
   int               state;
   string            info;
  };
struct STrig
  {
   string            id, track, country, match, ifsoft, ifmid, ifhot;
   double            soft, hot;
   int               flatbefore;
  };
struct SGroup { string id; double cap; };
struct SDay   { string date; double mult; int maxn; };
struct STrack { string name; string active; string why; };
struct STrip  { string id, sym, bsym; int dir; double move; int minutes; int block; };

//--- plan globals
string   gVer = "", gWeek = "", gNote = "", gSource = "", gNet = "";
datetime gMadeU = 0, gExpU = 0, gFlatU = 0;
double   gRisk = 0.5, gWeekStop = 2.0, gSpreadX = 3.0;
int      gMaxDay = 3, gNewsMin = 15, gNewsImp = 3;   // 3 = HIGH, 2 = MEDIUM
SSetup   gS[];
STrig    gT[];
SGroup   gG[];
SDay     gD[];
STrack   gK[];
STrip    gP[];
string   gClose[];
string   gNextEvent = "";
datetime gLastPoll = 0;
bool     gHalted = false;
string   gHaltWhy = "";
CTrade   trade;

//--- blackout cache
string   gBlkCur[];
datetime gBlkAt[];
bool     gBlkVal[];

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
string K(string s) { return "WP_" + gWeek + "_" + s; }
void   GSet(string k, double v) { GlobalVariableSet(K(k), v); }
double GGet(string k, double d = 0) { return GlobalVariableCheck(K(k)) ? GlobalVariableGet(K(k)) : d; }
void   GDel(string k) { if(GlobalVariableCheck(K(k))) GlobalVariableDel(K(k)); }

int SrvOffset()
  {
   long d = (long)(TimeTradeServer() - TimeGMT());
   return (int)(MathRound(d / 1800.0) * 1800);
  }
datetime U2S(datetime u) { return u == 0 ? 0 : u + SrvOffset(); }
datetime NowS() { return TimeTradeServer(); }

string Trim(string s) { StringTrimLeft(s); StringTrimRight(s); return s; }
string Lower(string s) { StringToLower(s); return s; }

string Tok(string &t[], string key, string def = "")
  {
   string p = key + "=";
   for(int i = 0; i < ArraySize(t); i++)
      if(StringFind(t[i], p) == 0)
         return StringSubstr(t[i], StringLen(p));
   return def;
  }
double TokD(string &t[], string key, double def = 0) { string v = Tok(t, key); return v == "" ? def : StringToDouble(v); }
int    TokI(string &t[], string key, int def = 0)    { string v = Tok(t, key); return v == "" ? def : (int)StringToInteger(v); }

datetime ParseU(string s)
  {
   if(s == "") return 0;
   StringReplace(s, "-", ".");
   StringReplace(s, "T", " ");
   return StringToTime(s);
  }
ENUM_TIMEFRAMES ParseTF(string s)
  {
   if(s == "M30") return PERIOD_M30;
   if(s == "H1")  return PERIOD_H1;
   if(s == "D1")  return PERIOD_D1;
   return PERIOD_H4;
  }
string TFName(ENUM_TIMEFRAMES tf)
  {
   if(tf == PERIOD_M30) return "M30";
   if(tf == PERIOD_H1)  return "H1";
   if(tf == PERIOD_D1)  return "D1";
   return "H4";
  }
string StateName(int st)
  {
   switch(st)
     {
      case ST_IDLE:    return "waiting";
      case ST_ARMED:   return "ARMED - looking for 30m OB";
      case ST_PENDING: return "ORDER placed";
      case ST_OPEN:    return "IN TRADE";
      case ST_DONE:    return "done";
      case ST_DEAD:    return "invalidated";
     }
   return "?";
  }

void Alert2(string msg)
  {
   string m = "WeeklyPlanEA: " + msg;
   Print(m);
   SendNotification(m);   // works when MetaQuotes ID is set in MT5 options
  }

//--- find the broker's name for a plan symbol (handles suffixes like EURUSD.r, EURUSDm, GOLD)
string ResolveSymbol(string s)
  {
   if(SymbolSelect(s, true) && SymbolInfoInteger(s, SYMBOL_DIGITS) > 0) return s;
   int n = SymbolsTotal(false);
   for(int i = 0; i < n; i++)
     {
      string nm = SymbolName(i, false);
      if(StringFind(nm, s) == 0) { SymbolSelect(nm, true); return nm; }
     }
   if(s == "XAUUSD")
     {
      for(int i = 0; i < n; i++)
        {
         string nm = SymbolName(i, false);
         if(StringFind(nm, "GOLD") == 0) { SymbolSelect(nm, true); return nm; }
        }
     }
   return "";
  }

//+------------------------------------------------------------------+
//| Plan parsing                                                     |
//+------------------------------------------------------------------+
bool ParsePlan(string text)
  {
   string lines[];
   StringReplace(text, "\r", "");
   StringReplace(text, "\t", " ");
   int nl = StringSplit(text, '\n', lines);
   if(nl <= 0) return false;

   //--- find version first; reject files without a PLAN line
   string ver = "";
   for(int i = 0; i < nl; i++)
     {
      string ln = Trim(lines[i]);
      if(StringFind(ln, "PLAN ") == 0)
        {
         string t[]; StringSplit(ln, ' ', t);
         ver = Tok(t, "ver");
         break;
        }
     }
   if(ver == "") { gNet = "plan file has no PLAN ver= line - ignored"; return false; }
   if(ver == gVer) return true;   // nothing new

   ArrayResize(gS, 0); ArrayResize(gT, 0); ArrayResize(gG, 0);
   ArrayResize(gD, 0); ArrayResize(gK, 0); ArrayResize(gP, 0); ArrayResize(gClose, 0);
   gRisk = 0.5; gWeekStop = 2.0; gMaxDay = 3; gNewsMin = 15; gNewsImp = 3; gSpreadX = 3.0;
   gFlatU = 0; gExpU = 0; gMadeU = 0; gNote = "";

   for(int i = 0; i < nl; i++)
     {
      string ln = Trim(lines[i]);
      if(ln == "" || StringGetCharacter(ln, 0) == '#') continue;
      string t[];
      int nt = StringSplit(ln, ' ', t);
      if(nt < 1) continue;
      string rec = t[0];

      if(rec == "PLAN")
        {
         gVer  = Tok(t, "ver");
         gWeek = Tok(t, "week", "W");
         gMadeU = ParseU(Tok(t, "made"));
         gExpU  = ParseU(Tok(t, "expires"));
         gFlatU = ParseU(Tok(t, "flat"));
         gNote  = Tok(t, "note");
         StringReplace(gNote, "_", " ");
        }
      else if(rec == "RISK")
        {
         gRisk     = TokD(t, "pct", 0.5);
         gWeekStop = TokD(t, "weekstop", 2.0);
         gMaxDay   = TokI(t, "maxday", 3);
         gNewsMin  = TokI(t, "newsmin", 15);
         gSpreadX  = TokD(t, "spreadx", 3.0);
         gNewsImp  = (Tok(t, "news", "HIGH") == "MEDIUM") ? 2 : 3;
        }
      else if(rec == "GROUP")
        {
         int k = ArraySize(gG); ArrayResize(gG, k + 1);
         gG[k].id = Tok(t, "id"); gG[k].cap = TokD(t, "cap", 1.0);
        }
      else if(rec == "DAY")
        {
         int k = ArraySize(gD); ArrayResize(gD, k + 1);
         string d = Tok(t, "date"); StringReplace(d, "-", ".");
         gD[k].date = d; gD[k].mult = TokD(t, "mult", 1.0); gD[k].maxn = TokI(t, "max", gMaxDay);
        }
      else if(rec == "TRACK")
        {
         int k = ArraySize(gK); ArrayResize(gK, k + 1);
         gK[k].name = Tok(t, "name"); gK[k].active = Tok(t, "active", "BASE"); gK[k].why = "plan";
        }
      else if(rec == "TRIGGER")
        {
         int k = ArraySize(gT); ArrayResize(gT, k + 1);
         gT[k].id = Tok(t, "id"); gT[k].track = Tok(t, "track"); gT[k].country = Tok(t, "country");
         gT[k].match = Lower(Tok(t, "match"));
         StringReplace(gT[k].match, "_", " ");
         gT[k].soft = TokD(t, "soft"); gT[k].hot = TokD(t, "hot");
         gT[k].ifsoft = Tok(t, "ifsoft", "SOFT"); gT[k].ifmid = Tok(t, "ifmid", "INLINE"); gT[k].ifhot = Tok(t, "ifhot", "HOT");
         gT[k].flatbefore = TokI(t, "flatbefore", 0);
        }
      else if(rec == "SETUP")
        {
         int k = ArraySize(gS); ArrayResize(gS, k + 1);
         gS[k].id = Tok(t, "id"); gS[k].track = Tok(t, "track", "USD"); gS[k].scen = Tok(t, "scen", "ALL");
         gS[k].sym = Tok(t, "sym"); gS[k].bsym = ResolveSymbol(gS[k].sym);
         gS[k].dir = (Tok(t, "dir") == "SELL") ? -1 : 1;
         gS[k].trig = Tok(t, "trig", "BREAK");
         gS[k].lvl = TokD(t, "lvl"); gS[k].zlo = TokD(t, "zlo"); gS[k].zhi = TokD(t, "zhi");
         gS[k].inv = TokD(t, "inv"); gS[k].invtf = ParseTF(Tok(t, "invtf", "H4"));
         gS[k].tp1 = TokD(t, "tp1"); gS[k].tp2 = TokD(t, "tp2");
         gS[k].grp = Tok(t, "grp"); gS[k].rm = TokD(t, "rm", 1.0);
         gS[k].hold = TokI(t, "hold", 0); gS[k].window = TokI(t, "window", 24);
         gS[k].state = ST_IDLE; gS[k].info = "";
        }
      else if(rec == "TRIP")
        {
         int k = ArraySize(gP); ArrayResize(gP, k + 1);
         gP[k].id = Tok(t, "id"); gP[k].sym = Tok(t, "sym"); gP[k].bsym = ResolveSymbol(gP[k].sym);
         string d = Tok(t, "dir", "ANY");
         gP[k].dir = (d == "UP") ? 1 : (d == "DOWN" ? -1 : 0);
         gP[k].move = TokD(t, "move"); gP[k].minutes = TokI(t, "min", 5); gP[k].block = TokI(t, "block", 24);
        }
      else if(rec == "CLOSE")
        {
         int k = ArraySize(gClose); ArrayResize(gClose, k + 1);
         gClose[k] = ResolveSymbol(Tok(t, "sym"));
        }
     }
   return true;
  }

//--- after a new plan is loaded: restore states, apply fired triggers, run CLOSE records
void AfterPlanLoad()
  {
   gHalted = false; gHaltWhy = "";          // re-evaluated by CheckWeekStop / flat time
   for(int i = 0; i < ArraySize(gS); i++)
      gS[i].state = (int)GGet(gS[i].id + "_st", ST_IDLE);

   //--- calendar triggers that fired after this plan was written still win
   for(int i = 0; i < ArraySize(gT); i++)
     {
      double fu = GGet("tf_" + gT[i].id, 0);
      if(fu > 0 && (datetime)fu > gMadeU)
        {
         int c = (int)GGet("tc_" + gT[i].id, 2);
         string sc = (c == 1) ? gT[i].ifsoft : (c == 3 ? gT[i].ifhot : gT[i].ifmid);
         SetTrack(gT[i].track, sc, "event " + gT[i].id, false);
        }
     }

   //--- one-off CLOSE records
   if(!GlobalVariableCheck("WP_cl_" + gVer))
     {
      for(int i = 0; i < ArraySize(gClose); i++)
         if(gClose[i] != "") CloseSymbol(gClose[i], "plan CLOSE record");
      GlobalVariableSet("WP_cl_" + gVer, 1);
     }

   for(int i = 0; i < ArraySize(gK); i++) SyncTrack(gK[i].name);
   Alert2("plan " + gVer + " loaded (" + gSource + "). " + gNote);
  }

bool LoadCache(string &txt)
  {
   int h = FileOpen("WeeklyPlanEA_plan.txt", FILE_READ | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(h == INVALID_HANDLE) return false;
   txt = "";
   while(!FileIsEnding(h)) txt += FileReadString(h) + "\n";
   FileClose(h);
   return StringLen(txt) > 0;
  }
void SaveCache(string txt)
  {
   int h = FileOpen("WeeklyPlanEA_plan.txt", FILE_WRITE | FILE_TXT | FILE_COMMON | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   FileWriteString(h, txt);
   FileClose(h);
  }

bool ApplyText(string txt, string source)
  {
   string old = gVer;
   if(!ParsePlan(txt)) return false;
   if(gVer != old) { gSource = source; AfterPlanLoad(); }
   return true;
  }

void Poll()
  {
   gLastPoll = TimeLocal();
   string url = InpPlanURL + (StringFind(InpPlanURL, "?") < 0 ? "?" : "&") + "t=" + IntegerToString((long)TimeLocal());
   char data[], res[];
   string hdr;
   ResetLastError();
   int code = WebRequest("GET", url, "", 5000, data, res, hdr);
   if(code == 200)
     {
      string txt = CharArrayToString(res, 0, WHOLE_ARRAY, CP_UTF8);
      if(ApplyText(txt, "GitHub")) { SaveCache(txt); gNet = "plan OK " + TimeToString(TimeLocal(), TIME_MINUTES); }
     }
   else
     {
      if(code == -1)
         gNet = "WebRequest blocked: add https://raw.githubusercontent.com in Tools > Options > Expert Advisors (err " + IntegerToString(GetLastError()) + ")";
      else
         gNet = "plan download HTTP " + IntegerToString(code);
      if(gVer == "")
        {
         string c;
         if(LoadCache(c)) ApplyText(c, "cache");
        }
     }
  }

//+------------------------------------------------------------------+
//| Scenario tracks                                                  |
//+------------------------------------------------------------------+
string TrackActive(string name)
  {
   for(int i = 0; i < ArraySize(gK); i++) if(gK[i].name == name) return gK[i].active;
   return "BASE";
  }
bool InScen(SSetup &s)
  {
   if(s.scen == "ALL") return true;
   return StringFind("," + s.scen + ",", "," + TrackActive(s.track) + ",") >= 0;
  }
void SetTrack(string name, string scen, string why, bool sync = true)
  {
   int k = -1;
   for(int i = 0; i < ArraySize(gK); i++) if(gK[i].name == name) k = i;
   if(k < 0) { k = ArraySize(gK); ArrayResize(gK, k + 1); gK[k].name = name; gK[k].active = ""; }
   if(gK[k].active == scen) return;
   gK[k].active = scen; gK[k].why = why;
   Alert2("track " + name + " -> " + scen + " (" + why + ")");
   if(sync) SyncTrack(name);
  }
//--- cancel orders and close trades that no longer fit; arm NOW setups
void SyncTrack(string name)
  {
   for(int i = 0; i < ArraySize(gS); i++)
     {
      if(gS[i].track != name) continue;
      bool act = InScen(gS[i]);
      if(!act)
        {
         if(gS[i].state == ST_PENDING) { DeleteOrder(gS[i]); SetState(i, ST_ARMED); }
         if(gS[i].state == ST_ARMED || gS[i].state == ST_IDLE) { if(gS[i].state == ST_ARMED) SetState(i, ST_IDLE); }
         if(gS[i].state == ST_OPEN && !SameIdeaActive(gS[i]))
           { ClosePos(gS[i], "scenario changed"); SetState(i, ST_DONE); }
        }
      else if(gS[i].trig == "NOW" && gS[i].state == ST_IDLE && GGet(gS[i].id + "_now") == 0)
        {
         GSet(gS[i].id + "_arm", (double)NowS());
         GSet(gS[i].id + "_now", 1);
         SetState(i, ST_ARMED);
        }
     }
  }
bool SameIdeaActive(SSetup &s)
  {
   for(int j = 0; j < ArraySize(gS); j++)
      if(gS[j].id != s.id && gS[j].bsym == s.bsym && gS[j].dir == s.dir && InScen(gS[j])) return true;
   return InScen(s);
  }
void SetState(int i, int st)
  {
   if(gS[i].state == st) return;
   gS[i].state = st;
   GSet(gS[i].id + "_st", st);
  }

//+------------------------------------------------------------------+
//| Calendar                                                         |
//+------------------------------------------------------------------+
bool NameMatches(string name, string match)
  {
   name = Lower(name);
   string parts[];
   int n = StringSplit(match, '+', parts);
   for(int i = 0; i < n; i++)
     {
      string p = Trim(parts[i]);
      if(p == "") continue;
      if(StringGetCharacter(p, 0) == '~')
        { if(StringFind(name, StringSubstr(p, 1)) >= 0) return false; }
      else if(StringFind(name, p) < 0) return false;
     }
   return true;
  }

void CheckTriggers()
  {
   gNextEvent = "";
   datetime now = NowS();
   datetime madeS = U2S(gMadeU);
   for(int i = 0; i < ArraySize(gT); i++)
     {
      if(GGet("tf_" + gT[i].id, 0) > 0) continue;
      MqlCalendarValue v[];
      if(CalendarValueHistory(v, now - 2 * 86400, now + 6 * 86400, gT[i].country) <= 0) continue;
      int best = -1;
      for(int j = 0; j < ArraySize(v); j++)
        {
         if(v[j].time <= madeS) continue;
         MqlCalendarEvent ev;
         if(!CalendarEventById(v[j].event_id, ev)) continue;
         if(!NameMatches(ev.name, gT[i].match)) continue;
         if(best < 0 || v[j].time < v[best].time) best = j;
        }
      if(best < 0) { gNextEvent += gT[i].id + ": not found in MT5 calendar  "; continue; }

      MqlCalendarEvent ev;
      CalendarEventById(v[best].event_id, ev);
      if(v[best].time > now)
        {
         gNextEvent += gT[i].id + " " + TimeToString(v[best].time, TIME_DATE | TIME_MINUTES) + " srv  ";
         if(gT[i].flatbefore > 0 && v[best].time - now <= gT[i].flatbefore * 60 && GGet("fb_" + gT[i].id) == 0)
           {
            MqlCalendarCountry c;
            if(CalendarCountryById(ev.country_id, c)) CloseCurrency(c.currency, "flat before " + gT[i].id);
            GSet("fb_" + gT[i].id, 1);
           }
         continue;
        }
      if(!v[best].HasActualValue())
        {
         gNextEvent += gT[i].id + ": released, waiting for actual  ";
         continue;
        }
      double a = v[best].GetActualValue();
      int code = (a <= gT[i].soft) ? 1 : (a >= gT[i].hot ? 3 : 2);
      string sc = (code == 1) ? gT[i].ifsoft : (code == 3 ? gT[i].ifhot : gT[i].ifmid);
      GSet("tf_" + gT[i].id, (double)TimeGMT());
      GSet("tc_" + gT[i].id, code);
      SetTrack(gT[i].track, sc, gT[i].id + " actual " + DoubleToString(a, 2));
     }
  }

//--- high-impact news within +/- newsmin minutes for either currency of the symbol
bool CurrencyBlackout(string cur)
  {
   datetime now = NowS();
   for(int i = 0; i < ArraySize(gBlkCur); i++)
      if(gBlkCur[i] == cur && now - gBlkAt[i] < 60) return gBlkVal[i];
   bool hit = false;
   MqlCalendarValue v[];
   if(CalendarValueHistory(v, now - gNewsMin * 60, now + gNewsMin * 60, NULL, cur) > 0)
      for(int j = 0; j < ArraySize(v) && !hit; j++)
        {
         MqlCalendarEvent ev;
         if(CalendarEventById(v[j].event_id, ev) && (int)ev.importance >= gNewsImp) hit = true;
        }
   int k = -1;
   for(int i = 0; i < ArraySize(gBlkCur); i++) if(gBlkCur[i] == cur) k = i;
   if(k < 0) { k = ArraySize(gBlkCur); ArrayResize(gBlkCur, k + 1); ArrayResize(gBlkAt, k + 1); ArrayResize(gBlkVal, k + 1); gBlkCur[k] = cur; }
   gBlkAt[k] = now; gBlkVal[k] = hit;
   return hit;
  }
bool Blackout(string sym)
  {
   return CurrencyBlackout(SymbolInfoString(sym, SYMBOL_CURRENCY_BASE)) ||
          CurrencyBlackout(SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT));
  }

//+------------------------------------------------------------------+
//| Market checks                                                    |
//+------------------------------------------------------------------+
double ATR(MqlRates &r[], int period)
  {
   double s = 0; int n = 0;
   for(int i = 1; i <= period && i + 1 < ArraySize(r); i++)
     {
      double tr = MathMax(r[i].high - r[i].low, MathMax(MathAbs(r[i].high - r[i + 1].close), MathAbs(r[i].low - r[i + 1].close)));
      s += tr; n++;
     }
   return n > 0 ? s / n : 0;
  }

bool SpreadOK(string sym)
  {
   MqlRates r[]; ArraySetAsSeries(r, true);
   int n = CopyRates(sym, PERIOD_M5, 1, 50, r);
   if(n < 10) return true;
   double avg = 0; for(int i = 0; i < n; i++) avg += r[i].spread; avg /= n;
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   double cur = (SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID)) / pt;
   return avg <= 0 || cur <= gSpreadX * avg;
  }

bool SymbolBlocked(string sym)
  {
   for(int i = 0; i < ArraySize(gP); i++)
      if(gP[i].bsym == sym && GGet("tb_" + gP[i].id) > (double)TimeGMT()) return true;
   return false;
  }

void CheckTripwires()
  {
   for(int i = 0; i < ArraySize(gP); i++)
     {
      if(gP[i].bsym == "" || gP[i].move <= 0) continue;
      if(GGet("tb_" + gP[i].id) > (double)TimeGMT()) continue;
      MqlRates r[]; ArraySetAsSeries(r, true);
      int n = CopyRates(gP[i].bsym, PERIOD_M1, 0, gP[i].minutes + 1, r);
      if(n < 2) continue;
      double hh = r[0].high, ll = r[0].low;
      for(int j = 1; j < n; j++) { hh = MathMax(hh, r[j].high); ll = MathMin(ll, r[j].low); }
      double bid = SymbolInfoDouble(gP[i].bsym, SYMBOL_BID);
      bool down = (hh - bid) >= gP[i].move, up = (bid - ll) >= gP[i].move;
      bool fire = (gP[i].dir < 0 && down) || (gP[i].dir > 0 && up) || (gP[i].dir == 0 && (up || down));
      if(!fire) continue;
      GSet("tb_" + gP[i].id, (double)(TimeGMT() + gP[i].block * 3600));
      CloseSymbol(gP[i].bsym, "tripwire " + gP[i].id);
      Alert2("TRIPWIRE " + gP[i].id + " on " + gP[i].bsym + ": flat and blocked " + IntegerToString(gP[i].block) + "h");
     }
  }

double DayMult()
  {
   string d = TimeToString(TimeGMT(), TIME_DATE);
   for(int i = 0; i < ArraySize(gD); i++) if(gD[i].date == d) return gD[i].mult;
   return 1.0;
  }
int DayMax()
  {
   string d = TimeToString(TimeGMT(), TIME_DATE);
   for(int i = 0; i < ArraySize(gD); i++) if(gD[i].date == d) return gD[i].maxn;
   return gMaxDay;
  }
int TradesToday()
  {
   datetime u = TimeGMT();
   datetime from = U2S(u - (u % 86400));
   if(!HistorySelect(from, NowS() + 60)) return 0;
   int c = 0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(t, DEAL_MAGIC) == InpMagic && HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_IN) c++;
     }
   return c;
  }
double GroupCap(string grp)
  {
   for(int i = 0; i < ArraySize(gG); i++) if(gG[i].id == grp) return gG[i].cap;
   return 999;
  }
double GroupUsed(string grp)
  {
   double u = 0;
   for(int i = 0; i < ArraySize(gS); i++)
      if(gS[i].grp == grp && (gS[i].state == ST_PENDING || gS[i].state == ST_OPEN) && GGet(gS[i].id + "_be") == 0)
         u += GGet(gS[i].id + "_rk");
   return u;
  }

//--- week stop
void CheckWeekStop()
  {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(GGet("eq0") <= 0) GSet("eq0", eq);
   double eq0 = GGet("eq0");
   if(GGet("halt") > 0) { gHalted = true; if(gHaltWhy == "") gHaltWhy = "weekly stop hit earlier"; return; }
   if(eq0 > 0 && (eq0 - eq) / eq0 * 100.0 >= gWeekStop)
     {
      CloseAll("weekly stop");
      GSet("halt", 1);
      gHalted = true; gHaltWhy = "weekly stop -" + DoubleToString(gWeekStop, 1) + "% hit";
      Alert2("WEEKLY STOP HIT - all closed, no trading until next week's plan");
     }
  }

//+------------------------------------------------------------------+
//| Orders and positions                                             |
//+------------------------------------------------------------------+
string Cmt(SSetup &s) { return "WP:" + s.id; }

bool FindPos(SSetup &s, ulong &ticket)
  {
   ulong id = (ulong)GGet(s.id + "_tk");
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if((id > 0 && (ulong)PositionGetInteger(POSITION_IDENTIFIER) == id) || PositionGetString(POSITION_COMMENT) == Cmt(s))
        { ticket = t; return true; }
     }
   return false;
  }
bool FindOrder(SSetup &s, ulong &ticket)
  {
   ulong id = (ulong)GGet(s.id + "_tk");
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if(t == id || OrderGetString(ORDER_COMMENT) == Cmt(s)) { ticket = t; return true; }
     }
   return false;
  }
void DeleteOrder(SSetup &s)
  {
   ulong t;
   if(FindOrder(s, t)) trade.OrderDelete(t);
  }
void ClosePos(SSetup &s, string why)
  {
   ulong t;
   if(FindPos(s, t)) { trade.PositionClose(t); Alert2("closed " + s.id + " (" + why + ")"); }
  }
void CloseSymbol(string sym, string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic && PositionGetString(POSITION_SYMBOL) == sym) trade.PositionClose(t);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic && OrderGetString(ORDER_SYMBOL) == sym) trade.OrderDelete(t);
     }
   for(int i = 0; i < ArraySize(gS); i++)
      if(gS[i].bsym == sym && (gS[i].state == ST_OPEN || gS[i].state == ST_PENDING))
         SetState(i, gS[i].state == ST_OPEN ? ST_DONE : ST_ARMED);
   Print("WeeklyPlanEA: flat ", sym, " (", why, ")");
  }
void CloseCurrency(string cur, string why)
  {
   for(int i = 0; i < ArraySize(gS); i++)
     {
      string b = gS[i].bsym;
      if(b == "") continue;
      if(SymbolInfoString(b, SYMBOL_CURRENCY_BASE) == cur || SymbolInfoString(b, SYMBOL_CURRENCY_PROFIT) == cur)
         CloseSymbol(b, why);
     }
  }
void CloseAll(string why)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic) trade.PositionClose(t);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagic) trade.OrderDelete(t);
     }
   for(int i = 0; i < ArraySize(gS); i++)
      if(gS[i].state == ST_OPEN || gS[i].state == ST_PENDING) SetState(i, ST_DONE);
   Alert2("closed everything (" + why + ")");
  }
//--- delete EA orders whose setup was removed from the plan
void CleanupOrphans()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      string c = OrderGetString(ORDER_COMMENT);
      bool known = false;
      for(int j = 0; j < ArraySize(gS); j++) if(c == Cmt(gS[j])) known = true;
      if(!known) trade.OrderDelete(t);
     }
  }

//+------------------------------------------------------------------+
//| Setup logic                                                      |
//+------------------------------------------------------------------+
bool Invalidated(SSetup &s)
  {
   if(s.inv <= 0) return false;
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(CopyRates(s.bsym, s.invtf, 0, 3, r) < 2) return false;
   if(r[1].time + PeriodSeconds(s.invtf) <= U2S(gMadeU)) return false;   // only candles closed after the plan
   return (s.dir > 0) ? (r[1].close < s.inv) : (r[1].close > s.inv);
  }

bool CheckTrigger(SSetup &s, datetime &armAt)
  {
   datetime madeS = U2S(gMadeU);
   MqlRates r[]; ArraySetAsSeries(r, true);
   if(s.trig == "BREAK")
     {
      if(CopyRates(s.bsym, PERIOD_H4, 0, 3, r) < 2) return false;
      if(r[1].time + PeriodSeconds(PERIOD_H4) <= madeS) return false;
      bool ok = (s.dir > 0) ? (r[1].close > s.lvl) : (r[1].close < s.lvl);
      if(ok) armAt = r[1].time + PeriodSeconds(PERIOD_H4);
      return ok;
     }
   if(s.trig == "REJECT")
     {
      int n = CopyRates(s.bsym, PERIOD_H1, 0, 120, r);
      if(n < 3) return false;
      bool touched = false;
      for(int j = 1; j < n; j++)
        {
         if(r[j].time + 3600 <= madeS) break;
         if((s.dir > 0 && r[j].low <= s.zhi) || (s.dir < 0 && r[j].high >= s.zlo)) { touched = true; break; }
        }
      if(!touched) return false;
      bool ok = (s.dir > 0) ? (r[1].close > s.zhi && r[1].close > r[1].open)
                            : (r[1].close < s.zlo && r[1].close < r[1].open);
      if(ok) armAt = r[1].time + 3600;
      return ok;
     }
   return false;   // NOW setups are armed by SyncTrack
  }

//--- first unmitigated 30-minute order block formed since the trigger
bool FindOB(SSetup &s, double &entry, double &sl)
  {
   MqlRates r[]; ArraySetAsSeries(r, true);
   int n = CopyRates(s.bsym, PERIOD_M30, 0, OB_LOOKBACK + 20, r);
   if(n < 20) return false;
   double atr = ATR(r, 14);
   datetime minT = (datetime)GGet(s.id + "_arm") - 2 * 3600;
   for(int i = 2; i < OB_LOOKBACK && i < n; i++)
     {
      if(r[i].time < minT) break;
      int disp = -1;
      if(s.dir > 0)
        {
         if(r[i].close >= r[i].open) continue;                 // need a bearish candle
         for(int j = i - 1; j >= 1; j--) if(r[j].close > r[i].high) { disp = j; break; }
         if(disp < 0) continue;
         bool mit = false;
         for(int k = disp - 1; k >= 1; k--) if(r[k].low <= r[i].high) { mit = true; break; }
         if(mit) continue;
         entry = r[i].high; sl = r[i].low - SL_BUFFER_ATR * atr;
        }
      else
        {
         if(r[i].close <= r[i].open) continue;                 // need a bullish candle
         for(int j = i - 1; j >= 1; j--) if(r[j].close < r[i].low) { disp = j; break; }
         if(disp < 0) continue;
         bool mit = false;
         for(int k = disp - 1; k >= 1; k--) if(r[k].high >= r[i].low) { mit = true; break; }
         if(mit) continue;
         entry = r[i].low; sl = r[i].high + SL_BUFFER_ATR * atr;
        }
      if(MathAbs(entry - sl) < 0.3 * atr) continue;
      return true;
     }
   return false;
  }

double Lots(string sym, double dist, double riskPct)
  {
   double money = AccountInfoDouble(ACCOUNT_EQUITY) * riskPct / 100.0;
   double tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tv <= 0) tv = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0 || dist <= 0) return 0;
   double lots = money / (dist / ts * tv);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), vmax = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   lots = MathFloor(lots / step) * step;
   if(lots < vmin) return 0;
   return MathMin(lots, vmax);
  }

string Gate(SSetup &s)
  {
   if(!InpAutoTrade) return "auto-trade OFF (alert only)";
   if(gHalted) return gHaltWhy;
   if(gExpU > 0 && TimeGMT() >= gExpU) return "plan expired - waiting for new plan";
   if(SymbolBlocked(s.bsym)) return "blocked by tripwire";
   if(Blackout(s.bsym)) return "news blackout";
   if(!SpreadOK(s.bsym)) return "spread too wide";
   if(DayMult() <= 0) return "no trading today";
   if(TradesToday() >= DayMax()) return "daily trade limit reached";
   return "";
  }

void TryEntry(int i)
  {
   if(NowS() - (datetime)GGet(gS[i].id + "_try") < RETRY_SEC) return;
   double entry = 0, sl = 0;
   if(!FindOB(gS[i], entry, sl)) { gS[i].info = "no clean 30m OB yet"; return; }

   string g = Gate(gS[i]);
   if(g != "")
     {
      if(gS[i].info != g && !InpAutoTrade) Alert2(gS[i].id + " " + gS[i].bsym + " setup ready: OB entry " + DoubleToString(entry, (int)SymbolInfoInteger(gS[i].bsym, SYMBOL_DIGITS)));
      gS[i].info = g; return;
     }

   string sym = gS[i].bsym;
   int dg = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double dist = MathAbs(entry - sl);
   double tp1 = gS[i].tp1 > 0 ? gS[i].tp1 : entry + gS[i].dir * 1.5 * dist;
   double tp2 = gS[i].tp2 > 0 ? gS[i].tp2 : entry + gS[i].dir * 3.0 * dist;
   if(gS[i].dir * (tp2 - entry) <= 0 || gS[i].dir * (tp1 - entry) <= 0) { gS[i].info = "target already passed"; return; }
   if(MathAbs(tp2 - entry) / dist < MIN_RR) { gS[i].info = "RR below 1.5 - skipped this OB"; return; }

   double rp = gRisk * DayMult() * gS[i].rm;
   if(gS[i].grp != "" && GroupUsed(gS[i].grp) + rp > GroupCap(gS[i].grp) + 1e-9) { gS[i].info = "group " + gS[i].grp + " risk cap full"; return; }
   double lots = Lots(sym, dist, rp);
   if(lots <= 0) { gS[i].info = "lot size below broker minimum"; return; }

   entry = NormalizeDouble(entry, dg); sl = NormalizeDouble(sl, dg);
   tp1 = NormalizeDouble(tp1, dg); tp2 = NormalizeDouble(tp2, dg);
   trade.SetTypeFillingBySymbol(sym);
   GSet(gS[i].id + "_try", (double)NowS());

   double ask = SymbolInfoDouble(sym, SYMBOL_ASK), bid = SymbolInfoDouble(sym, SYMBOL_BID);
   bool ok = false, market = false;
   if(gS[i].dir > 0)
     {
      if(ask > entry) ok = trade.BuyLimit(lots, entry, sym, sl, tp2, ORDER_TIME_GTC, 0, Cmt(gS[i]));
      else if(bid > sl) { ok = trade.Buy(lots, sym, 0, sl, tp2, Cmt(gS[i])); market = true; }
     }
   else
     {
      if(bid < entry) ok = trade.SellLimit(lots, entry, sym, sl, tp2, ORDER_TIME_GTC, 0, Cmt(gS[i]));
      else if(ask < sl) { ok = trade.Sell(lots, sym, 0, sl, tp2, Cmt(gS[i])); market = true; }
     }
   if(!ok) { gS[i].info = "order rejected: " + trade.ResultRetcodeDescription(); return; }

   GSet(gS[i].id + "_tk", (double)trade.ResultOrder());
   GSet(gS[i].id + "_rk", rp);
   GSet(gS[i].id + "_t1", tp1);
   GSet(gS[i].id + "_pa", (double)NowS());
   SetState(i, market ? ST_OPEN : ST_PENDING);
   Alert2(gS[i].id + (gS[i].dir > 0 ? " BUY " : " SELL ") + sym + (market ? " market" : " limit @" + DoubleToString(entry, dg)) +
          " SL " + DoubleToString(sl, dg) + " TP1 " + DoubleToString(tp1, dg) + " TP2 " + DoubleToString(tp2, dg) +
          " risk " + DoubleToString(rp, 2) + "%");
  }

void ManageOpen(int i)
  {
   ulong t;
   if(!FindPos(gS[i], t)) { SetState(i, ST_DONE); gS[i].info = "closed"; return; }
   if(!PositionSelectByTicket(t)) return;
   string sym = gS[i].bsym;
   long type = PositionGetInteger(POSITION_TYPE);
   double open = PositionGetDouble(POSITION_PRICE_OPEN), vol = PositionGetDouble(POSITION_VOLUME);
   double tp = PositionGetDouble(POSITION_TP);
   double px = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);
   double tp1 = GGet(gS[i].id + "_t1");

   //--- take half at tp1, stop to entry
   if(GGet(gS[i].id + "_be") == 0 && tp1 > 0 &&
      ((type == POSITION_TYPE_BUY && px >= tp1) || (type == POSITION_TYPE_SELL && px <= tp1)))
     {
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP), vmin = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double half = MathFloor(vol / 2.0 / step) * step;
      if(half >= vmin && vol - half >= vmin) trade.PositionClosePartial(t, half);
      if(PositionSelectByTicket(t)) trade.PositionModify(t, open, tp);
      GSet(gS[i].id + "_be", 1);
      Alert2(gS[i].id + " TP1 hit: half closed, stop at entry");
     }

   //--- max holding time
   if(gS[i].hold > 0 && NowS() - (datetime)PositionGetInteger(POSITION_TIME) > gS[i].hold * 3600)
     { ClosePos(gS[i], "max hold " + IntegerToString(gS[i].hold) + "h"); SetState(i, ST_DONE); return; }

   double pnl = PositionGetDouble(POSITION_PROFIT);
   gS[i].info = "P/L " + DoubleToString(pnl, 2) + (GGet(gS[i].id + "_be") > 0 ? " | half off, risk-free" : "");
  }

void ManageSetup(int i)
  {
   if(gS[i].bsym == "") { gS[i].info = "symbol " + gS[i].sym + " not found at this broker"; return; }
   int st = gS[i].state;
   if(st == ST_DONE || st == ST_DEAD) return;

   if(st != ST_IDLE && Invalidated(gS[i]))   // invalidation applies once the idea has triggered
     {
      if(st == ST_PENDING) DeleteOrder(gS[i]);
      if(st == ST_OPEN) ClosePos(gS[i], "invalidated");
      SetState(i, ST_DEAD);
      Alert2(gS[i].id + " invalidated by " + TFName(gS[i].invtf) + " close beyond " + DoubleToString(gS[i].inv, (int)SymbolInfoInteger(gS[i].bsym, SYMBOL_DIGITS)));
      return;
     }

   if(st == ST_OPEN) { ManageOpen(i); return; }
   if(!InScen(gS[i])) { gS[i].info = "not active in scenario " + TrackActive(gS[i].track); return; }

   if(st == ST_IDLE)
     {
      if(gS[i].trig == "NOW") { gS[i].info = "waits for its scenario"; return; }
      datetime armAt = 0;
      if(CheckTrigger(gS[i], armAt))
        {
         GSet(gS[i].id + "_arm", (double)armAt);
         SetState(i, ST_ARMED);
         Alert2(gS[i].id + " " + gS[i].bsym + " ARMED (" + gS[i].trig + ")");
        }
      else gS[i].info = (gS[i].trig == "BREAK") ? "waiting for H4 close beyond " + DoubleToString(gS[i].lvl, (int)SymbolInfoInteger(gS[i].bsym, SYMBOL_DIGITS))
                                                : "waiting for rejection of " + DoubleToString(gS[i].zlo, (int)SymbolInfoInteger(gS[i].bsym, SYMBOL_DIGITS)) + "-" + DoubleToString(gS[i].zhi, (int)SymbolInfoInteger(gS[i].bsym, SYMBOL_DIGITS));
      return;
     }

   if(st == ST_ARMED)
     {
      if(NowS() - (datetime)GGet(gS[i].id + "_arm") > gS[i].window * 3600)
        {
         SetState(i, gS[i].trig == "NOW" ? ST_DONE : ST_IDLE);
         gS[i].info = "entry window expired";
         return;
        }
      TryEntry(i);
      return;
     }

   if(st == ST_PENDING)
     {
      ulong t;
      if(!FindOrder(gS[i], t))
        {
         ulong p;
         if(FindPos(gS[i], p)) { SetState(i, ST_OPEN); Alert2(gS[i].id + " filled"); }
         else SetState(i, ST_ARMED);
         return;
        }
      if(NowS() - (datetime)GGet(gS[i].id + "_pa") > PENDING_HOURS * 3600 || Blackout(gS[i].bsym))
        {
         trade.OrderDelete(t);
         SetState(i, ST_ARMED);
         gS[i].info = "limit cancelled (time/news) - re-scanning";
         return;
        }
      gS[i].info = "limit waiting for fill";
     }
  }

//+------------------------------------------------------------------+
//| Panel                                                            |
//+------------------------------------------------------------------+
void Panel()
  {
   string s = "WeeklyPlanEA  |  plan " + (gVer == "" ? "NONE" : gVer) + "  |  " + gNet + "\n";
   if(gVer == "") { Comment(s + "Waiting for the plan file..."); return; }
   double eq0 = GGet("eq0"), eq = AccountInfoDouble(ACCOUNT_EQUITY);
   s += "Plan: " + gNote + "\n";
   s += "Risk " + DoubleToString(gRisk, 2) + "% x" + DoubleToString(DayMult(), 2) + " today | trades today " + IntegerToString(TradesToday()) + "/" + IntegerToString(DayMax()) +
        " | week " + (eq0 > 0 ? DoubleToString((eq - eq0) / eq0 * 100, 2) : "0") + "% (stop -" + DoubleToString(gWeekStop, 1) + "%)" +
        (InpAutoTrade ? "" : " | ALERT-ONLY") + (gHalted ? " | HALTED: " + gHaltWhy : "") + "\n";
   s += "Scenarios: ";
   for(int i = 0; i < ArraySize(gK); i++) s += gK[i].name + "=" + gK[i].active + " (" + gK[i].why + ")  ";
   s += "\nEvents: " + (gNextEvent == "" ? "-" : gNextEvent) + "\n";
   s += "--------------------------------------------------------------\n";
   for(int i = 0; i < ArraySize(gS); i++)
      s += gS[i].id + "  " + (gS[i].bsym == "" ? gS[i].sym : gS[i].bsym) + (gS[i].dir > 0 ? " BUY " : " SELL ") +
           "[" + gS[i].scen + "]  " + StateName(gS[i].state) + "  " + gS[i].info + "\n";
   Comment(s);
  }

//+------------------------------------------------------------------+
//| Events                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetAsyncMode(false);
   gLastPoll = 0;                           // first timer tick downloads the plan
   string c;
   if(LoadCache(c)) ApplyText(c, "cache");
   EventSetTimer(TIMER_SEC);
   Panel();
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int reason) { EventKillTimer(); Comment(""); }

void OnTimer()
  {
   if(TimeLocal() - gLastPoll >= POLL_SEC) Poll();
   if(gVer != "")
     {
      CheckWeekStop();
      if(gFlatU > 0 && TimeGMT() >= gFlatU)
        {
         if(GGet("flatdone") == 0) { CloseAll("end-of-week flat time"); GSet("flatdone", 1); }
         gHalted = true; gHaltWhy = "week closed (flat time passed)";
        }
      CheckTriggers();
      CheckTripwires();
      CleanupOrphans();
      for(int i = 0; i < ArraySize(gS); i++) ManageSetup(i);
     }
   Panel();
  }
void OnTick() {}
//+------------------------------------------------------------------+
