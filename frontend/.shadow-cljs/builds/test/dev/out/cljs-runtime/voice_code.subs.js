goog.provide('voice_code.subs');
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("connection","status","connection/status",1925154065),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"status","status",-1997798413)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("connection","authenticated?","connection/authenticated?",1992756571),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"authenticated?","authenticated?",-1988130123)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("connection","error","connection/error",1725472530),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"error","error",-978969032)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("connection","reconnect-attempts","connection/reconnect-attempts",1648074191),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"reconnect-attempts","reconnect-attempts",-1994972943)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("sessions","all","sessions/all",1617752491),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return new cljs.core.Keyword(null,"sessions","sessions",-699316392).cljs$core$IFn$_invoke$arity$1(db);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("sessions","by-id","sessions/by-id",-187498968),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,p__12029){
var vec__12036 = p__12029;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12036,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12036,(1),null);
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),session_id], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("sessions","active-id","sessions/active-id",733530269),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return new cljs.core.Keyword(null,"active-session-id","active-session-id",943086451).cljs$core$IFn$_invoke$arity$1(db);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("sessions","active","sessions/active",-1555945161),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","all","sessions/all",1617752491)], null),new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","active-id","sessions/active-id",733530269)], null),(function (p__12065,_){
var vec__12066 = p__12065;
var sessions = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12066,(0),null);
var active_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12066,(1),null);
return cljs.core.get.cljs$core$IFn$_invoke$arity$2(sessions,active_id);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("sessions","directories","sessions/directories",781650228),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","all","sessions/all",1617752491)], null),(function (sessions,_){
return cljs.core.sort_by.cljs$core$IFn$_invoke$arity$3(new cljs.core.Keyword(null,"last-modified","last-modified",1593411791),cljs.core._GT_,cljs.core.map.cljs$core$IFn$_invoke$arity$2((function (p__12085){
var vec__12089 = p__12085;
var dir = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12089,(0),null);
var sessions__$1 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12089,(1),null);
return new cljs.core.PersistentArrayMap(null, 3, [new cljs.core.Keyword(null,"directory","directory",-58912409),dir,new cljs.core.Keyword(null,"session-count","session-count",587323089),cljs.core.count(sessions__$1),new cljs.core.Keyword(null,"last-modified","last-modified",1593411791),cljs.core.apply.cljs$core$IFn$_invoke$arity$2(cljs.core.max,cljs.core.map.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"last-modified","last-modified",1593411791),sessions__$1))], null);
}),cljs.core.group_by(new cljs.core.Keyword(null,"working-directory","working-directory",-145423687),cljs.core.vals(sessions))));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("sessions","for-directory","sessions/for-directory",-1359973835),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","all","sessions/all",1617752491)], null),(function (sessions,p__12096){
var vec__12097 = p__12096;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12097,(0),null);
var directory = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12097,(1),null);
return cljs.core.sort_by.cljs$core$IFn$_invoke$arity$3(new cljs.core.Keyword(null,"last-modified","last-modified",1593411791),cljs.core._GT_,cljs.core.filter.cljs$core$IFn$_invoke$arity$2((function (p1__12095_SHARP_){
return cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(directory,new cljs.core.Keyword(null,"working-directory","working-directory",-145423687).cljs$core$IFn$_invoke$arity$1(p1__12095_SHARP_));
}),cljs.core.vals(sessions)));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("messages","all","messages/all",1367318778),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return new cljs.core.Keyword(null,"messages","messages",345434482).cljs$core$IFn$_invoke$arity$1(db);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("messages","for-session","messages/for-session",-1469675482),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,p__12100){
var vec__12101 = p__12100;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12101,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12101,(1),null);
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$3(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.PersistentVector.EMPTY);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("messages","for-active-session","messages/for-active-session",-1412466024),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("messages","all","messages/all",1367318778)], null),new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","active-id","sessions/active-id",733530269)], null),(function (p__12105,_){
var vec__12107 = p__12105;
var messages = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12107,(0),null);
var active_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12107,(1),null);
return cljs.core.get.cljs$core$IFn$_invoke$arity$3(messages,active_id,cljs.core.PersistentVector.EMPTY);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880).cljs$core$IFn$_invoke$arity$1(db);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("session","locked?","session/locked?",-989538101),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880)], null),(function (locked_sessions,p__12110){
var vec__12111 = p__12110;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12111,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12111,(1),null);
return cljs.core.contains_QMARK_(locked_sessions,session_id);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("active-session","locked?","active-session/locked?",-1986741018),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880)], null),new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","active-id","sessions/active-id",733530269)], null),(function (p__12114,_){
var vec__12115 = p__12114;
var locked_sessions = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12115,(0),null);
var active_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12115,(1),null);
return cljs.core.contains_QMARK_(locked_sessions,active_id);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("commands","available","commands/available",-853482527),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"available","available",-1470697127)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("commands","running","commands/running",950058119),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"running","running",1554969103)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("commands","history","commands/history",-568651020),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"history","history",-247395220)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("resources","list","resources/list",-1550635008),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"resources","resources",1632806811),new cljs.core.Keyword(null,"list","list",765357683)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("resources","pending-uploads","resources/pending-uploads",-1928544106),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"resources","resources",1632806811),new cljs.core.Keyword(null,"pending-uploads","pending-uploads",314048169)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("settings","all","settings/all",1588794929),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return new cljs.core.Keyword(null,"settings","settings",1556144875).cljs$core$IFn$_invoke$arity$1(db);
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("settings","server-url","settings/server-url",-627533455),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"settings","settings",1556144875),new cljs.core.Keyword(null,"server-url","server-url",1982223374)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("settings","server-port","settings/server-port",-233394173),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"settings","settings",1556144875),new cljs.core.Keyword(null,"server-port","server-port",663745648)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("ui","loading?","ui/loading?",1905710757),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"loading?","loading?",1905707049)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("ui","current-error","ui/current-error",1366499768),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,_){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"current-error","current-error",1366495244)], null));
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("ui","draft","ui/draft",1421834462),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(function (db,p__12120){
var vec__12121 = p__12120;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12121,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12121,(1),null);
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$3(db,new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"drafts","drafts",1523624562),session_id], null),"");
})], 0));
re_frame.core.reg_sub.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword("ui","active-draft","ui/active-draft",-414101064),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"<-","<-",760412998),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","active-id","sessions/active-id",733530269)], null),(function (active_id,_){
return re_frame.core.subscribe.cljs$core$IFn$_invoke$arity$1(new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ui","draft","ui/draft",1421834462),active_id], null));
})], 0));

//# sourceMappingURL=voice_code.subs.js.map
