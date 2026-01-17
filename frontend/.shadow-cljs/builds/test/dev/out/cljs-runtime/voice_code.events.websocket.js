goog.provide('voice_code.events.websocket');
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","connect","ws/connect",1232825645),(function (p__13389,_){
var map__13390 = p__13389;
var map__13390__$1 = cljs.core.__destructure_map(map__13390);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13390__$1,new cljs.core.Keyword(null,"db","db",993250759));
var map__13391 = new cljs.core.Keyword(null,"settings","settings",1556144875).cljs$core$IFn$_invoke$arity$1(db);
var map__13391__$1 = cljs.core.__destructure_map(map__13391);
var server_url = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13391__$1,new cljs.core.Keyword(null,"server-url","server-url",1982223374));
var server_port = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13391__$1,new cljs.core.Keyword(null,"server-port","server-port",663745648));
return new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"status","status",-1997798413)], null),new cljs.core.Keyword(null,"connecting","connecting",-1347943866)),new cljs.core.Keyword("ws","connect","ws/connect",1232825645),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"server-url","server-url",1982223374),server_url,new cljs.core.Keyword(null,"server-port","server-port",663745648),server_port], null)], null);
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","connected","ws/connected",-169836913),(function (p__13392,_){
var map__13394 = p__13392;
var map__13394__$1 = cljs.core.__destructure_map(map__13394);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13394__$1,new cljs.core.Keyword(null,"db","db",993250759));
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"status","status",-1997798413)], null),new cljs.core.Keyword(null,"connected","connected",-169833045))], null);
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","disconnected","ws/disconnected",-1908000542),(function (p__13395,p__13396){
var map__13397 = p__13395;
var map__13397__$1 = cljs.core.__destructure_map(map__13397);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13397__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13398 = p__13396;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13398,(0),null);
var map__13401 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13398,(1),null);
var map__13401__$1 = cljs.core.__destructure_map(map__13401);
var code = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13401__$1,new cljs.core.Keyword(null,"code","code",1586293142));
var reason = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13401__$1,new cljs.core.Keyword(null,"reason","reason",-2070751759));
var attempts = cljs.core.get_in.cljs$core$IFn$_invoke$arity$3(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"reconnect-attempts","reconnect-attempts",-1994972943)], null),(0));
var max_attempts = (20);
var should_reconnect_QMARK_ = (attempts < max_attempts);
var delay_ms = ((should_reconnect_QMARK_)?cljs.core.min.cljs$core$IFn$_invoke$arity$2(((1000) * Math.pow((2),attempts)),(30000)):null);
var G__13405 = new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.update_in.cljs$core$IFn$_invoke$arity$3(cljs.core.assoc_in(cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"status","status",-1997798413)], null),new cljs.core.Keyword(null,"disconnected","disconnected",-1908014586)),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"authenticated?","authenticated?",-1988130123)], null),false),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"reconnect-attempts","reconnect-attempts",-1994972943)], null),cljs.core.fnil.cljs$core$IFn$_invoke$arity$2(cljs.core.inc,(0))),new cljs.core.Keyword("ws","stop-ping-timer","ws/stop-ping-timer",-389980801),null], null);
if(should_reconnect_QMARK_){
return cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(G__13405,new cljs.core.Keyword("ws","schedule-reconnect","ws/schedule-reconnect",1843305927),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"delay-ms","delay-ms",-59253516),delay_ms,new cljs.core.Keyword(null,"config","config",994861415),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"server-url","server-url",1982223374),cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"settings","settings",1556144875),new cljs.core.Keyword(null,"server-url","server-url",1982223374)], null)),new cljs.core.Keyword(null,"server-port","server-port",663745648),cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"settings","settings",1556144875),new cljs.core.Keyword(null,"server-port","server-port",663745648)], null))], null)], null));
} else {
return G__13405;
}
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","error","ws/error",-978964716),(function (db,p__13407){
var vec__13408 = p__13407;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13408,(0),null);
var error = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13408,(1),null);
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"error","error",-978969032)], null),(""+cljs.core.str.cljs$core$IFn$_invoke$arity$1(error)));
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","message-received","ws/message-received",287223475),(function (_,p__13412){
var vec__13413 = p__13412;
var ___$1 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13413,(0),null);
var map__13416 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13413,(1),null);
var map__13416__$1 = cljs.core.__destructure_map(map__13416);
var msg = map__13416__$1;
var type = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13416__$1,new cljs.core.Keyword(null,"type","type",1174270348));
var G__13417 = type;
switch (G__13417) {
case "hello":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","handle-hello","ws/handle-hello",764594500),msg], null)], null);

break;
case "connected":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","handle-connected","ws/handle-connected",874687778),msg], null)], null);

break;
case "auth_error":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","handle-auth-error","ws/handle-auth-error",-1642139941),msg], null)], null);

break;
case "response":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","handle-response","ws/handle-response",260001194),msg], null)], null);

break;
case "ack":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","handle-ack","ws/handle-ack",-681381620),msg], null)], null);

break;
case "error":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","handle-error","ws/handle-error",1613860192),msg], null)], null);

break;
case "replay":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","handle-replay","ws/handle-replay",-804985622),msg], null)], null);

break;
case "session_list":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-list","sessions/handle-list",-1849063142),msg], null)], null);

break;
case "recent_sessions":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-recent","sessions/handle-recent",-1121861631),msg], null)], null);

break;
case "session_created":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-created","sessions/handle-created",-1504804614),msg], null)], null);

break;
case "session_history":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-history","sessions/handle-history",781774467),msg], null)], null);

break;
case "session_updated":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-updated","sessions/handle-updated",1595929140),msg], null)], null);

break;
case "turn_complete":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-turn-complete","sessions/handle-turn-complete",1261514999),msg], null)], null);

break;
case "session_locked":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-locked","sessions/handle-locked",1954352279),msg], null)], null);

break;
case "available_commands":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("commands","handle-available","commands/handle-available",-1450101493),msg], null)], null);

break;
case "command_started":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("commands","handle-started","commands/handle-started",-1611289320),msg], null)], null);

break;
case "command_output":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("commands","handle-output","commands/handle-output",-1476010400),msg], null)], null);

break;
case "command_complete":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("commands","handle-complete","commands/handle-complete",-287805612),msg], null)], null);

break;
case "command_history":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("commands","handle-history","commands/handle-history",-1237111666),msg], null)], null);

break;
case "command_output_full":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("commands","handle-output-full","commands/handle-output-full",806408206),msg], null)], null);

break;
case "compaction_complete":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-compaction-complete","sessions/handle-compaction-complete",-330278594),msg], null)], null);

break;
case "compaction_error":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","handle-compaction-error","sessions/handle-compaction-error",1013990003),msg], null)], null);

break;
case "resources_list":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("resources","handle-list","resources/handle-list",-941705310),msg], null)], null);

break;
case "file_uploaded":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("resources","handle-uploaded","resources/handle-uploaded",475563654),msg], null)], null);

break;
case "resource_deleted":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("resources","handle-deleted","resources/handle-deleted",-449382544),msg], null)], null);

break;
case "available_recipes":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("recipes","handle-available","recipes/handle-available",1177503536),msg], null)], null);

break;
case "recipe_started":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("recipes","handle-started","recipes/handle-started",-2109187983),msg], null)], null);

break;
case "recipe_exited":
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("recipes","handle-exited","recipes/handle-exited",884518702),msg], null)], null);

break;
case "pong":
return null;

break;
default:
return console.warn("Unknown message type:",type);

}
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","handle-hello","ws/handle-hello",764594500),(function (p__13420,p__13421){
var map__13422 = p__13420;
var map__13422__$1 = cljs.core.__destructure_map(map__13422);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13422__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13423 = p__13421;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13423,(0),null);
var map__13426 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13423,(1),null);
var map__13426__$1 = cljs.core.__destructure_map(map__13426);
var auth_version = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13426__$1,new cljs.core.Keyword(null,"auth-version","auth-version",437829749));
return new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"status","status",-1997798413)], null),new cljs.core.Keyword(null,"authenticating","authenticating",-1022679476)),new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","send-connect","ws/send-connect",-2134842545)], null)], null);
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","send-connect","ws/send-connect",-2134842545),(function (p__13427,_){
var map__13428 = p__13427;
var map__13428__$1 = cljs.core.__destructure_map(map__13428);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13428__$1,new cljs.core.Keyword(null,"db","db",993250759));
var map__13429 = db;
var map__13429__$1 = cljs.core.__destructure_map(map__13429);
var api_key = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13429__$1,new cljs.core.Keyword(null,"api-key","api-key",1037904031));
var ios_session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13429__$1,new cljs.core.Keyword(null,"ios-session-id","ios-session-id",1674306223));
var map__13430 = new cljs.core.Keyword(null,"settings","settings",1556144875).cljs$core$IFn$_invoke$arity$1(db);
var map__13430__$1 = cljs.core.__destructure_map(map__13430);
var recent_sessions_limit = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13430__$1,new cljs.core.Keyword(null,"recent-sessions-limit","recent-sessions-limit",560228192));
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword("ws","send","ws/send",-652154486),new cljs.core.PersistentArrayMap(null, 4, [new cljs.core.Keyword(null,"type","type",1174270348),"connect",new cljs.core.Keyword(null,"api-key","api-key",1037904031),api_key,new cljs.core.Keyword(null,"session-id","session-id",-1147060351),ios_session_id,new cljs.core.Keyword(null,"recent-sessions-limit","recent-sessions-limit",560228192),recent_sessions_limit], null)], null);
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","handle-connected","ws/handle-connected",874687778),(function (p__13431,p__13432){
var map__13433 = p__13431;
var map__13433__$1 = cljs.core.__destructure_map(map__13433);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13433__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13434 = p__13432;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13434,(0),null);
var map__13437 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13434,(1),null);
var map__13437__$1 = cljs.core.__destructure_map(map__13437);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13437__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
return new cljs.core.PersistentArrayMap(null, 3, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.assoc_in(cljs.core.assoc_in(cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"status","status",-1997798413)], null),new cljs.core.Keyword(null,"connected","connected",-169833045)),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"authenticated?","authenticated?",-1988130123)], null),true),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"reconnect-attempts","reconnect-attempts",-1994972943)], null),(0)),new cljs.core.Keyword("ws","start-ping-timer","ws/start-ping-timer",-1059944181),null,new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("sessions","resubscribe-all","sessions/resubscribe-all",1768172111)], null)], null);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","handle-auth-error","ws/handle-auth-error",-1642139941),(function (db,p__13438){
var vec__13439 = p__13438;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13439,(0),null);
var map__13442 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13439,(1),null);
var map__13442__$1 = cljs.core.__destructure_map(map__13442);
var message = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13442__$1,new cljs.core.Keyword(null,"message","message",-406056002));
return cljs.core.assoc_in(cljs.core.assoc_in(cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"status","status",-1997798413)], null),new cljs.core.Keyword(null,"disconnected","disconnected",-1908014586)),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"authenticated?","authenticated?",-1988130123)], null),false),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"connection","connection",-123599300),new cljs.core.Keyword(null,"error","error",-978969032)], null),(function (){var or__5142__auto__ = message;
if(cljs.core.truth_(or__5142__auto__)){
return or__5142__auto__;
} else {
return "Authentication failed";
}
})());
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","handle-response","ws/handle-response",260001194),(function (p__13447,p__13448){
var map__13449 = p__13447;
var map__13449__$1 = cljs.core.__destructure_map(map__13449);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13449__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13450 = p__13448;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13450,(0),null);
var map__13453 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13450,(1),null);
var map__13453__$1 = cljs.core.__destructure_map(map__13453);
var success = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13453__$1,new cljs.core.Keyword(null,"success","success",1890645906));
var text = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13453__$1,new cljs.core.Keyword(null,"text","text",-1790561697));
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13453__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
var message_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13453__$1,new cljs.core.Keyword(null,"message-id","message-id",-1564847547));
var usage = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13453__$1,new cljs.core.Keyword(null,"usage","usage",-1583752910));
var cost = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13453__$1,new cljs.core.Keyword(null,"cost","cost",-1094861735));
var error = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13453__$1,new cljs.core.Keyword(null,"error","error",-978969032));
if(cljs.core.truth_(success)){
return new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.update.cljs$core$IFn$_invoke$arity$4(cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.fnil.cljs$core$IFn$_invoke$arity$2(cljs.core.conj,cljs.core.PersistentVector.EMPTY),new cljs.core.PersistentArrayMap(null, 6, [new cljs.core.Keyword(null,"id","id",-1388402092),cljs.core.random_uuid(),new cljs.core.Keyword(null,"session-id","session-id",-1147060351),session_id,new cljs.core.Keyword(null,"role","role",-736691072),new cljs.core.Keyword(null,"assistant","assistant",-918311387),new cljs.core.Keyword(null,"text","text",-1790561697),text,new cljs.core.Keyword(null,"timestamp","timestamp",579478971),(new Date()),new cljs.core.Keyword(null,"status","status",-1997798413),new cljs.core.Keyword(null,"confirmed","confirmed",-487126323)], null)),new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.disj,session_id),new cljs.core.Keyword(null,"dispatch-n","dispatch-n",-504469236),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","send-message-ack","ws/send-message-ack",1146697297),message_id], null),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("persistence","save-message","persistence/save-message",1922037332),session_id], null)], null)], null);
} else {
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.update.cljs$core$IFn$_invoke$arity$4(cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"current-error","current-error",1366495244)], null),error),new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.disj,session_id)], null);
}
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","send-message-ack","ws/send-message-ack",1146697297),(function (_,p__13455){
var vec__13456 = p__13455;
var ___$1 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13456,(0),null);
var message_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13456,(1),null);
if(cljs.core.truth_(message_id)){
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword("ws","send","ws/send",-652154486),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"type","type",1174270348),"message_ack",new cljs.core.Keyword(null,"message-id","message-id",-1564847547),message_id], null)], null);
} else {
return null;
}
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","handle-ack","ws/handle-ack",-681381620),(function (db,p__13460){
var vec__13461 = p__13460;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13461,(0),null);
var ___$1 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13461,(1),null);
return db;
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","handle-error","ws/handle-error",1613860192),(function (db,p__13464){
var vec__13465 = p__13464;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13465,(0),null);
var map__13468 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13465,(1),null);
var map__13468__$1 = cljs.core.__destructure_map(map__13468);
var message = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13468__$1,new cljs.core.Keyword(null,"message","message",-406056002));
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13468__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
var G__13469 = cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"current-error","current-error",1366495244)], null),message);
if(cljs.core.truth_(session_id)){
return cljs.core.update.cljs$core$IFn$_invoke$arity$4(G__13469,new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.disj,session_id);
} else {
return G__13469;
}
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("ws","handle-replay","ws/handle-replay",-804985622),(function (p__13472,p__13473){
var map__13474 = p__13472;
var map__13474__$1 = cljs.core.__destructure_map(map__13474);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13474__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13475 = p__13473;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13475,(0),null);
var map__13478 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13475,(1),null);
var map__13478__$1 = cljs.core.__destructure_map(map__13478);
var message_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13478__$1,new cljs.core.Keyword(null,"message-id","message-id",-1564847547));
var message = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13478__$1,new cljs.core.Keyword(null,"message","message",-406056002));
var map__13479 = message;
var map__13479__$1 = cljs.core.__destructure_map(map__13479);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13479__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
var text = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13479__$1,new cljs.core.Keyword(null,"text","text",-1790561697));
var role = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13479__$1,new cljs.core.Keyword(null,"role","role",-736691072));
var timestamp = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13479__$1,new cljs.core.Keyword(null,"timestamp","timestamp",579478971));
return new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.fnil.cljs$core$IFn$_invoke$arity$2(cljs.core.conj,cljs.core.PersistentVector.EMPTY),new cljs.core.PersistentArrayMap(null, 6, [new cljs.core.Keyword(null,"id","id",-1388402092),(function (){var or__5142__auto__ = message_id;
if(cljs.core.truth_(or__5142__auto__)){
return or__5142__auto__;
} else {
return cljs.core.random_uuid();
}
})(),new cljs.core.Keyword(null,"session-id","session-id",-1147060351),session_id,new cljs.core.Keyword(null,"role","role",-736691072),cljs.core.keyword.cljs$core$IFn$_invoke$arity$1(role),new cljs.core.Keyword(null,"text","text",-1790561697),text,new cljs.core.Keyword(null,"timestamp","timestamp",579478971),(new Date(timestamp)),new cljs.core.Keyword(null,"status","status",-1997798413),new cljs.core.Keyword(null,"confirmed","confirmed",-487126323)], null)),new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","send-message-ack","ws/send-message-ack",1146697297),message_id], null)], null);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-list","sessions/handle-list",-1849063142),(function (db,p__13480){
var vec__13481 = p__13480;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13481,(0),null);
var map__13484 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13481,(1),null);
var map__13484__$1 = cljs.core.__destructure_map(map__13484);
var sessions = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13484__$1,new cljs.core.Keyword(null,"sessions","sessions",-699316392));
return cljs.core.reduce.cljs$core$IFn$_invoke$arity$3((function (db__$1,session){
return cljs.core.assoc_in(db__$1,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),new cljs.core.Keyword(null,"session-id","session-id",-1147060351).cljs$core$IFn$_invoke$arity$1(session)], null),new cljs.core.PersistentArrayMap(null, 6, [new cljs.core.Keyword(null,"id","id",-1388402092),new cljs.core.Keyword(null,"session-id","session-id",-1147060351).cljs$core$IFn$_invoke$arity$1(session),new cljs.core.Keyword(null,"backend-name","backend-name",-2065177492),new cljs.core.Keyword(null,"name","name",1843675177).cljs$core$IFn$_invoke$arity$1(session),new cljs.core.Keyword(null,"working-directory","working-directory",-145423687),new cljs.core.Keyword(null,"working-directory","working-directory",-145423687).cljs$core$IFn$_invoke$arity$1(session),new cljs.core.Keyword(null,"last-modified","last-modified",1593411791),(new Date(new cljs.core.Keyword(null,"last-modified","last-modified",1593411791).cljs$core$IFn$_invoke$arity$1(session))),new cljs.core.Keyword(null,"message-count","message-count",-1268963013),new cljs.core.Keyword(null,"message-count","message-count",-1268963013).cljs$core$IFn$_invoke$arity$1(session),new cljs.core.Keyword(null,"preview","preview",451279890),new cljs.core.Keyword(null,"preview","preview",451279890).cljs$core$IFn$_invoke$arity$1(session)], null));
}),db,sessions);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-recent","sessions/handle-recent",-1121861631),(function (db,p__13487){
var vec__13488 = p__13487;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13488,(0),null);
var map__13491 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13488,(1),null);
var map__13491__$1 = cljs.core.__destructure_map(map__13491);
var sessions = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13491__$1,new cljs.core.Keyword(null,"sessions","sessions",-699316392));
return cljs.core.reduce.cljs$core$IFn$_invoke$arity$3((function (db__$1,session){
return cljs.core.assoc_in(db__$1,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),new cljs.core.Keyword(null,"session-id","session-id",-1147060351).cljs$core$IFn$_invoke$arity$1(session)], null),new cljs.core.PersistentArrayMap(null, 4, [new cljs.core.Keyword(null,"id","id",-1388402092),new cljs.core.Keyword(null,"session-id","session-id",-1147060351).cljs$core$IFn$_invoke$arity$1(session),new cljs.core.Keyword(null,"backend-name","backend-name",-2065177492),new cljs.core.Keyword(null,"name","name",1843675177).cljs$core$IFn$_invoke$arity$1(session),new cljs.core.Keyword(null,"working-directory","working-directory",-145423687),new cljs.core.Keyword(null,"working-directory","working-directory",-145423687).cljs$core$IFn$_invoke$arity$1(session),new cljs.core.Keyword(null,"last-modified","last-modified",1593411791),(new Date(new cljs.core.Keyword(null,"last-modified","last-modified",1593411791).cljs$core$IFn$_invoke$arity$1(session)))], null));
}),db,sessions);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-created","sessions/handle-created",-1504804614),(function (db,p__13496){
var vec__13497 = p__13496;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13497,(0),null);
var map__13500 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13497,(1),null);
var map__13500__$1 = cljs.core.__destructure_map(map__13500);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13500__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
var name = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13500__$1,new cljs.core.Keyword(null,"name","name",1843675177));
var working_directory = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13500__$1,new cljs.core.Keyword(null,"working-directory","working-directory",-145423687));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),session_id], null),new cljs.core.PersistentArrayMap(null, 5, [new cljs.core.Keyword(null,"id","id",-1388402092),session_id,new cljs.core.Keyword(null,"backend-name","backend-name",-2065177492),name,new cljs.core.Keyword(null,"working-directory","working-directory",-145423687),working_directory,new cljs.core.Keyword(null,"last-modified","last-modified",1593411791),(new Date()),new cljs.core.Keyword(null,"message-count","message-count",-1268963013),(0)], null));
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-history","sessions/handle-history",781774467),(function (db,p__13501){
var vec__13502 = p__13501;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13502,(0),null);
var map__13505 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13502,(1),null);
var map__13505__$1 = cljs.core.__destructure_map(map__13505);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13505__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
var messages = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13505__$1,new cljs.core.Keyword(null,"messages","messages",345434482));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.mapv.cljs$core$IFn$_invoke$arity$2((function (msg){
return new cljs.core.PersistentArrayMap(null, 6, [new cljs.core.Keyword(null,"id","id",-1388402092),new cljs.core.Keyword(null,"id","id",-1388402092).cljs$core$IFn$_invoke$arity$1(msg),new cljs.core.Keyword(null,"session-id","session-id",-1147060351),session_id,new cljs.core.Keyword(null,"role","role",-736691072),cljs.core.keyword.cljs$core$IFn$_invoke$arity$1(new cljs.core.Keyword(null,"role","role",-736691072).cljs$core$IFn$_invoke$arity$1(msg)),new cljs.core.Keyword(null,"text","text",-1790561697),new cljs.core.Keyword(null,"text","text",-1790561697).cljs$core$IFn$_invoke$arity$1(msg),new cljs.core.Keyword(null,"timestamp","timestamp",579478971),(new Date(new cljs.core.Keyword(null,"timestamp","timestamp",579478971).cljs$core$IFn$_invoke$arity$1(msg))),new cljs.core.Keyword(null,"status","status",-1997798413),new cljs.core.Keyword(null,"confirmed","confirmed",-487126323)], null);
}),messages));
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-updated","sessions/handle-updated",1595929140),(function (db,p__13507){
var vec__13508 = p__13507;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13508,(0),null);
var map__13511 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13508,(1),null);
var map__13511__$1 = cljs.core.__destructure_map(map__13511);
var updates = map__13511__$1;
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13511__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),session_id], null),cljs.core.merge,cljs.core.dissoc.cljs$core$IFn$_invoke$arity$variadic(updates,new cljs.core.Keyword(null,"type","type",1174270348),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"session-id","session-id",-1147060351)], 0)));
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-turn-complete","sessions/handle-turn-complete",1261514999),(function (db,p__13513){
var vec__13514 = p__13513;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13514,(0),null);
var map__13517 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13514,(1),null);
var map__13517__$1 = cljs.core.__destructure_map(map__13517);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13517__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
return cljs.core.update.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.disj,session_id);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-locked","sessions/handle-locked",1954352279),(function (db,p__13518){
var vec__13519 = p__13518;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13519,(0),null);
var map__13522 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13519,(1),null);
var map__13522__$1 = cljs.core.__destructure_map(map__13522);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13522__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
return cljs.core.update.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.conj,session_id);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-compaction-complete","sessions/handle-compaction-complete",-330278594),(function (db,p__13523){
var vec__13524 = p__13523;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13524,(0),null);
var map__13527 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13524,(1),null);
var map__13527__$1 = cljs.core.__destructure_map(map__13527);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13527__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
return db;
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","handle-compaction-error","sessions/handle-compaction-error",1013990003),(function (db,p__13528){
var vec__13529 = p__13528;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13529,(0),null);
var map__13532 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13529,(1),null);
var map__13532__$1 = cljs.core.__destructure_map(map__13532);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13532__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
var error = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13532__$1,new cljs.core.Keyword(null,"error","error",-978969032));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"current-error","current-error",1366495244)], null),(""+"Compaction failed: "+cljs.core.str.cljs$core$IFn$_invoke$arity$1(error)));
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("sessions","resubscribe-all","sessions/resubscribe-all",1768172111),(function (p__13533,_){
var map__13534 = p__13533;
var map__13534__$1 = cljs.core.__destructure_map(map__13534);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13534__$1,new cljs.core.Keyword(null,"db","db",993250759));
var temp__5823__auto__ = new cljs.core.Keyword(null,"active-session-id","active-session-id",943086451).cljs$core$IFn$_invoke$arity$1(db);
if(cljs.core.truth_(temp__5823__auto__)){
var session_id = temp__5823__auto__;
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("session","subscribe","session/subscribe",-1853883934),session_id], null)], null);
} else {
return null;
}
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("session","subscribe","session/subscribe",-1853883934),(function (p__13535,p__13536){
var map__13537 = p__13535;
var map__13537__$1 = cljs.core.__destructure_map(map__13537);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13537__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13538 = p__13536;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13538,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13538,(1),null);
var last_message_id = new cljs.core.Keyword(null,"id","id",-1388402092).cljs$core$IFn$_invoke$arity$1(cljs.core.last(cljs.core.get.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"messages","messages",345434482).cljs$core$IFn$_invoke$arity$1(db),session_id)));
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword("ws","send","ws/send",-652154486),(function (){var G__13541 = new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"type","type",1174270348),"subscribe",new cljs.core.Keyword(null,"session-id","session-id",-1147060351),session_id], null);
if(cljs.core.truth_(last_message_id)){
return cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(G__13541,new cljs.core.Keyword(null,"last-message-id","last-message-id",-1578372287),last_message_id);
} else {
return G__13541;
}
})()], null);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("commands","handle-available","commands/handle-available",-1450101493),(function (db,p__13542){
var vec__13543 = p__13542;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13543,(0),null);
var map__13546 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13543,(1),null);
var map__13546__$1 = cljs.core.__destructure_map(map__13546);
var working_directory = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13546__$1,new cljs.core.Keyword(null,"working-directory","working-directory",-145423687));
var project_commands = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13546__$1,new cljs.core.Keyword(null,"project-commands","project-commands",855241894));
var general_commands = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13546__$1,new cljs.core.Keyword(null,"general-commands","general-commands",-2086582866));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"available","available",-1470697127),working_directory], null),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"project","project",1124394579),project_commands,new cljs.core.Keyword(null,"general","general",380803686),general_commands], null));
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("commands","handle-started","commands/handle-started",-1611289320),(function (db,p__13549){
var vec__13550 = p__13549;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13550,(0),null);
var map__13553 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13550,(1),null);
var map__13553__$1 = cljs.core.__destructure_map(map__13553);
var command_session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13553__$1,new cljs.core.Keyword(null,"command-session-id","command-session-id",2053090677));
var command_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13553__$1,new cljs.core.Keyword(null,"command-id","command-id",-1261579493));
var shell_command = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13553__$1,new cljs.core.Keyword(null,"shell-command","shell-command",-1662014064));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"running","running",1554969103),command_session_id], null),new cljs.core.PersistentArrayMap(null, 4, [new cljs.core.Keyword(null,"command-id","command-id",-1261579493),command_id,new cljs.core.Keyword(null,"shell-command","shell-command",-1662014064),shell_command,new cljs.core.Keyword(null,"output","output",-1105869043),"",new cljs.core.Keyword(null,"started-at","started-at",1318767912),(new Date())], null));
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("commands","handle-output","commands/handle-output",-1476010400),(function (db,p__13554){
var vec__13555 = p__13554;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13555,(0),null);
var map__13558 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13555,(1),null);
var map__13558__$1 = cljs.core.__destructure_map(map__13558);
var command_session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13558__$1,new cljs.core.Keyword(null,"command-session-id","command-session-id",2053090677));
var stream = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13558__$1,new cljs.core.Keyword(null,"stream","stream",1534941648));
var text = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13558__$1,new cljs.core.Keyword(null,"text","text",-1790561697));
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$5(db,new cljs.core.PersistentVector(null, 4, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"running","running",1554969103),command_session_id,new cljs.core.Keyword(null,"output","output",-1105869043)], null),cljs.core.str,text,"\n");
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("commands","handle-complete","commands/handle-complete",-287805612),(function (db,p__13559){
var vec__13560 = p__13559;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13560,(0),null);
var map__13563 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13560,(1),null);
var map__13563__$1 = cljs.core.__destructure_map(map__13563);
var command_session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13563__$1,new cljs.core.Keyword(null,"command-session-id","command-session-id",2053090677));
var exit_code = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13563__$1,new cljs.core.Keyword(null,"exit-code","exit-code",14028386));
var duration_ms = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13563__$1,new cljs.core.Keyword(null,"duration-ms","duration-ms",1993555055));
var cmd = cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"running","running",1554969103),command_session_id], null));
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(cljs.core.update.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.Keyword(null,"commands","commands",161008658),cljs.core.dissoc,command_session_id),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"history","history",-247395220)], null),cljs.core.conj,cljs.core.assoc.cljs$core$IFn$_invoke$arity$variadic(cmd,new cljs.core.Keyword(null,"exit-code","exit-code",14028386),exit_code,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"duration-ms","duration-ms",1993555055),duration_ms,new cljs.core.Keyword(null,"completed-at","completed-at",-1210511048),(new Date())], 0)));
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("commands","handle-history","commands/handle-history",-1237111666),(function (db,p__13564){
var vec__13565 = p__13564;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13565,(0),null);
var map__13568 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13565,(1),null);
var map__13568__$1 = cljs.core.__destructure_map(map__13568);
var sessions = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13568__$1,new cljs.core.Keyword(null,"sessions","sessions",-699316392));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"history","history",-247395220)], null),sessions);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("commands","handle-output-full","commands/handle-output-full",806408206),(function (db,p__13569){
var vec__13570 = p__13569;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13570,(0),null);
var map__13573 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13570,(1),null);
var map__13573__$1 = cljs.core.__destructure_map(map__13573);
var command_session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13573__$1,new cljs.core.Keyword(null,"command-session-id","command-session-id",2053090677));
var output = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13573__$1,new cljs.core.Keyword(null,"output","output",-1105869043));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 4, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"running","running",1554969103),command_session_id,new cljs.core.Keyword(null,"output","output",-1105869043)], null),output);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("resources","handle-list","resources/handle-list",-941705310),(function (db,p__13574){
var vec__13575 = p__13574;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13575,(0),null);
var map__13578 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13575,(1),null);
var map__13578__$1 = cljs.core.__destructure_map(map__13578);
var resources = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13578__$1,new cljs.core.Keyword(null,"resources","resources",1632806811));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"resources","resources",1632806811),new cljs.core.Keyword(null,"list","list",765357683)], null),resources);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("resources","handle-uploaded","resources/handle-uploaded",475563654),(function (db,p__13579){
var vec__13580 = p__13579;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13580,(0),null);
var resource = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13580,(1),null);
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$3(cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"resources","resources",1632806811),new cljs.core.Keyword(null,"list","list",765357683)], null),cljs.core.conj,resource),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"resources","resources",1632806811),new cljs.core.Keyword(null,"pending-uploads","pending-uploads",314048169)], null),cljs.core.dec);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("resources","handle-deleted","resources/handle-deleted",-449382544),(function (db,p__13584){
var vec__13585 = p__13584;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13585,(0),null);
var map__13588 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13585,(1),null);
var map__13588__$1 = cljs.core.__destructure_map(map__13588);
var filename = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13588__$1,new cljs.core.Keyword(null,"filename","filename",-1428840783));
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$3(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"resources","resources",1632806811),new cljs.core.Keyword(null,"list","list",765357683)], null),(function (resources){
return cljs.core.remove.cljs$core$IFn$_invoke$arity$2((function (p1__13583_SHARP_){
return cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"filename","filename",-1428840783).cljs$core$IFn$_invoke$arity$1(p1__13583_SHARP_),filename);
}),resources);
}));
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("recipes","handle-available","recipes/handle-available",1177503536),(function (db,p__13589){
var vec__13590 = p__13589;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13590,(0),null);
var map__13593 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13590,(1),null);
var map__13593__$1 = cljs.core.__destructure_map(map__13593);
var recipes = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13593__$1,new cljs.core.Keyword(null,"recipes","recipes",-325236209));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"recipes","recipes",-325236209),new cljs.core.Keyword(null,"available","available",-1470697127)], null),recipes);
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("recipes","handle-started","recipes/handle-started",-2109187983),(function (db,p__13594){
var vec__13595 = p__13594;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13595,(0),null);
var map__13598 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13595,(1),null);
var map__13598__$1 = cljs.core.__destructure_map(map__13598);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13598__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
var recipe_name = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13598__$1,new cljs.core.Keyword(null,"recipe-name","recipe-name",1756740629));
return cljs.core.assoc_in(db,new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"recipes","recipes",-325236209),new cljs.core.Keyword(null,"active","active",1895962068),session_id], null),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"name","name",1843675177),recipe_name,new cljs.core.Keyword(null,"started-at","started-at",1318767912),(new Date())], null));
}));
re_frame.core.reg_event_db.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("recipes","handle-exited","recipes/handle-exited",884518702),(function (db,p__13599){
var vec__13600 = p__13599;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13600,(0),null);
var map__13603 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13600,(1),null);
var map__13603__$1 = cljs.core.__destructure_map(map__13603);
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13603__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
return cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"recipes","recipes",-325236209),new cljs.core.Keyword(null,"active","active",1895962068)], null),cljs.core.dissoc,session_id);
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("prompt","send","prompt/send",440867858),(function (p__13604,p__13605){
var map__13606 = p__13604;
var map__13606__$1 = cljs.core.__destructure_map(map__13606);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13606__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13607 = p__13605;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13607,(0),null);
var map__13610 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13607,(1),null);
var map__13610__$1 = cljs.core.__destructure_map(map__13610);
var text = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13610__$1,new cljs.core.Keyword(null,"text","text",-1790561697));
var session_id = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13610__$1,new cljs.core.Keyword(null,"session-id","session-id",-1147060351));
var working_directory = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13610__$1,new cljs.core.Keyword(null,"working-directory","working-directory",-145423687));
var system_prompt = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13610__$1,new cljs.core.Keyword(null,"system-prompt","system-prompt",362593429));
var ios_session_id = new cljs.core.Keyword(null,"ios-session-id","ios-session-id",1674306223).cljs$core$IFn$_invoke$arity$1(db);
var message_id = (""+cljs.core.str.cljs$core$IFn$_invoke$arity$1(cljs.core.random_uuid()));
return new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"db","db",993250759),cljs.core.update_in.cljs$core$IFn$_invoke$arity$4(cljs.core.update.cljs$core$IFn$_invoke$arity$4(db,new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),cljs.core.conj,session_id),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.fnil.cljs$core$IFn$_invoke$arity$2(cljs.core.conj,cljs.core.PersistentVector.EMPTY),new cljs.core.PersistentArrayMap(null, 6, [new cljs.core.Keyword(null,"id","id",-1388402092),message_id,new cljs.core.Keyword(null,"session-id","session-id",-1147060351),session_id,new cljs.core.Keyword(null,"role","role",-736691072),new cljs.core.Keyword(null,"user","user",1532431356),new cljs.core.Keyword(null,"text","text",-1790561697),text,new cljs.core.Keyword(null,"timestamp","timestamp",579478971),(new Date()),new cljs.core.Keyword(null,"status","status",-1997798413),new cljs.core.Keyword(null,"sending","sending",-1806704862)], null)),new cljs.core.Keyword("ws","send","ws/send",-652154486),new cljs.core.PersistentArrayMap(null, 6, [new cljs.core.Keyword(null,"type","type",1174270348),"prompt",new cljs.core.Keyword(null,"text","text",-1790561697),text,new cljs.core.Keyword(null,"ios-session-id","ios-session-id",1674306223),ios_session_id,new cljs.core.Keyword(null,"session-id","session-id",-1147060351),session_id,new cljs.core.Keyword(null,"working-directory","working-directory",-145423687),working_directory,new cljs.core.Keyword(null,"system-prompt","system-prompt",362593429),system_prompt], null)], null);
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("prompt","send-from-draft","prompt/send-from-draft",1864174033),(function (p__13611,p__13612){
var map__13613 = p__13611;
var map__13613__$1 = cljs.core.__destructure_map(map__13613);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13613__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13614 = p__13612;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13614,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13614,(1),null);
var text = cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"drafts","drafts",1523624562),session_id], null));
var session = cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),session_id], null));
if(cljs.core.truth_((function (){var and__5140__auto__ = text;
if(cljs.core.truth_(and__5140__auto__)){
return cljs.core.seq(text);
} else {
return and__5140__auto__;
}
})())){
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"dispatch-n","dispatch-n",-504469236),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("prompt","send","prompt/send",440867858),new cljs.core.PersistentArrayMap(null, 3, [new cljs.core.Keyword(null,"text","text",-1790561697),text,new cljs.core.Keyword(null,"session-id","session-id",-1147060351),session_id,new cljs.core.Keyword(null,"working-directory","working-directory",-145423687),new cljs.core.Keyword(null,"working-directory","working-directory",-145423687).cljs$core$IFn$_invoke$arity$1(session)], null)], null),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ui","clear-draft","ui/clear-draft",526163605),session_id], null)], null)], null);
} else {
return null;
}
}));
re_frame.core.reg_event_fx.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword("session","compact","session/compact",-1719250764),(function (p__13618,p__13619){
var map__13620 = p__13618;
var map__13620__$1 = cljs.core.__destructure_map(map__13620);
var db = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13620__$1,new cljs.core.Keyword(null,"db","db",993250759));
var vec__13621 = p__13619;
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13621,(0),null);
var session_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13621,(1),null);
return new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword("ws","send","ws/send",-652154486),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"type","type",1174270348),"compact_session",new cljs.core.Keyword(null,"session-id","session-id",-1147060351),session_id], null)], null);
}));

//# sourceMappingURL=voice_code.events.websocket.js.map
