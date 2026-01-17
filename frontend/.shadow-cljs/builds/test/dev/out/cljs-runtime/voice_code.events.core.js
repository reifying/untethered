goog.provide('voice_code.events.core');
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"initialize-db","initialize-db",230998432),(function (_,___$1){
return voice_code.db.default_db;
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("app","initialize","app/initialize",609790584),(function (p__11972,_){
var map__11973 = p__11972;
var map__11973__$1 = cljs.core.__destructure_map(map__11973);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11973__$1,new cljs.core.Keyword(null,"db","db",993250759));
return new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.merge.cljs$core$IFn$_invoke$arity$variadic(cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([voice_code.db.default_db,db], 0)),new cljs.core.Keyword(null,"dispatch-n","dispatch-n",-504469236),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("persistence","load-settings","persistence/load-settings",-92199302)], null),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("persistence","load-api-key","persistence/load-api-key",-199823780)], null)], null)], null);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","set-active","sessions/set-active",2075690404),(function (db,p__11978){
var vec__11979 = p__11978;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11979,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11979,(1),null);
return cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(db,new cljs.core.Keyword(null,"active-session-id","active-session-id",943086451),session_id);
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","select","sessions/select",-1876239052),(function (p__11985,p__11986){
var map__11987 = p__11985;
var map__11987__$1 = cljs.core.__destructure_map(map__11987);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11987__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__11988 = p__11986;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11988,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11988,(1),null);
return new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(db,new cljs.core.Keyword(null,"active-session-id","active-session-id",943086451),session_id),new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("session","subscribe","session/subscribe",-1853883934),session_id], null)], null);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ui","set-loading","ui/set-loading",984633747),(function (db,p__11995){
var vec__11996 = p__11995;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11996,(0),null);
var loading_QMARK_ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11996,(1),null);
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"loading?","loading?",1905707049)], null),loading_QMARK_);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ui","set-error","ui/set-error",1627687496),(function (db,p__11999){
var vec__12000 = p__11999;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12000,(0),null);
var error = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12000,(1),null);
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"current-error","current-error",1366495244)], null),error);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ui","clear-error","ui/clear-error",1327349330),(function (db,_){
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"current-error","current-error",1366495244)], null),null);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ui","set-draft","ui/set-draft",-2023768225),(function (db,p__12007){
var vec__12008 = p__12007;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12008,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12008,(1),null);
var text = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12008,(2),null);
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"drafts","drafts",1523624562),session_id], null),text);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ui","clear-draft","ui/clear-draft",526163605),(function (db,p__12013){
var vec__12014 = p__12013;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12014,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12014,(1),null);
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"drafts","drafts",1523624562)], null),cljs.core.dissoc,session_id);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("settings","update","settings/update",-371393361),(function (db,p__12017){
var vec__12018 = p__12017;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12018,(0),null);
var key = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12018,(1),null);
var value = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12018,(2),null);
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"settings","settings",1556144875),key], null),value);
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("settings","save","settings/save",599995202),(function (p__12022,p__12023){
var map__12025 = p__12022;
var map__12025__$1 = cljs.core.__destructure_map(map__12025);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__12025__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__12026 = p__12023;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12026,(0),null);
var key = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12026,(1),null);
var value = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12026,(2),null);
return new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"settings","settings",1556144875),key], null),value),new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("persistence","save-setting","persistence/save-setting",-1892290408),key,value], null)], null);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","lock","sessions/lock",-827922501),(function (db,p__12032){
var vec__12033 = p__12032;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12033,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12033,(1),null);
return cljs.core.update.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.conj,session_id);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","unlock","sessions/unlock",254223057),(function (db,p__12039){
var vec__12040 = p__12039;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12040,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12040,(1),null);
return cljs.core.update.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.disj,session_id);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("messages","add","messages/add",294859927),(function (db,p__12044){
var vec__12045 = p__12044;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12045,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12045,(1),null);
var message = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12045,(2),null);
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.fnil.cljs$core$IFn$_invoke$arity$2(cljs.core.conj,cljs.core.PersistentVector.EMPTY),message);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("messages","add-many","messages/add-many",2140283585),(function (db,p__12049){
var vec__12050 = p__12049;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12050,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12050,(1),null);
var messages = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12050,(2),null);
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.fnil.cljs$core$IFn$_invoke$arity$2(cljs.core.into,cljs.core.PersistentVector.EMPTY),messages);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("messages","clear","messages/clear",1812813803),(function (db,p__12053){
var vec__12054 = p__12053;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12054,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12054,(1),null);
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.PersistentVector.EMPTY);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","add","sessions/add",1640392026),(function (db,p__12061){
var vec__12062 = p__12061;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12062,(0),null);
var session = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12062,(1),null);
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),new cljs.core.Keyword(null,"id","id",-1388402092).cljs$core$IFn$_invoke$arity$1(session)], null),session);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","add-many","sessions/add-many",241636210),(function (db,p__12070){
var vec__12071 = p__12070;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12071,(0),null);
var sessions = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12071,(1),null);
return cljs.core.reduce.cljs$core$IFn$_invoke$arity$3((function (db__$1,session){
return cljs.core.assoc_in(db__$1,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),new cljs.core.Keyword(null,"id","id",-1388402092).cljs$core$IFn$_invoke$arity$1(session)], null),session);
}),db,sessions);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","update","sessions/update",-334350299),(function (db,p__12075){
var vec__12076 = p__12075;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12076,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12076,(1),null);
var updates = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12076,(2),null);
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),session_id], null),cljs.core.merge,updates);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","remove","sessions/remove",728424869),(function (db,p__12080){
var vec__12081 = p__12080;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12081,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__12081,(1),null);
return cljs.core.update.cljs$core$IFn$_invoke$arity$4(cljs.core.update.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.Keyword(null,"sessions","sessions",-699316392),cljs.core.dissoc,session_id),new cljs.core.Keyword(null,"messages","messages",345434482),cljs.core.dissoc,session_id);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("db","update-in","db/update-in",1208917930),(function (db,p__12084){
var vec__12086 = p__12084;
var seq__12087 = cljs.core.seq(vec__12086);
var first__12088 = cljs.core.first(seq__12087);
var seq__12087__$1 = cljs.core.next(seq__12087);
var _ = first__12088;
var first__12088__$1 = cljs.core.first(seq__12087__$1);
var seq__12087__$2 = cljs.core.next(seq__12087__$1);
var path = first__12088__$1;
var first__12088__$2 = cljs.core.first(seq__12087__$2);
var seq__12087__$3 = cljs.core.next(seq__12087__$2);
var f = first__12088__$2;
var args = seq__12087__$3;
return cljs.core.apply.cljs$core$IFn$_invoke$arity$5(cljs.core.update_in,db,path,f,args);
}));

//# sourceMappingURL=voice_code.events.core.js.map
