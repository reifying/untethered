goog.provide('voice_code.websocket');
voice_code.websocket.ping_interval_ms = (30000);
voice_code.websocket.max_reconnect_attempts = (20);
voice_code.websocket.max_reconnect_delay_ms = (30000);
if((typeof voice_code !== 'undefined') && (typeof voice_code.websocket !== 'undefined') && (typeof voice_code.websocket.ws_atom !== 'undefined')){
} else {
voice_code.websocket.ws_atom = cljs.core.atom.cljs$core$IFn$_invoke$arity$1(null);
}
if((typeof voice_code !== 'undefined') && (typeof voice_code.websocket !== 'undefined') && (typeof voice_code.websocket.ping_timer !== 'undefined')){
} else {
voice_code.websocket.ping_timer = cljs.core.atom.cljs$core$IFn$_invoke$arity$1(null);
}
if((typeof voice_code !== 'undefined') && (typeof voice_code.websocket !== 'undefined') && (typeof voice_code.websocket.reconnect_timer !== 'undefined')){
} else {
voice_code.websocket.reconnect_timer = cljs.core.atom.cljs$core$IFn$_invoke$arity$1(null);
}
/**
 * Calculate reconnection delay with exponential backoff and jitter.
 */
voice_code.websocket.calculate_reconnect_delay = (function voice_code$websocket$calculate_reconnect_delay(attempt){
var base_delay = cljs.core.min.cljs$core$IFn$_invoke$arity$2(Math.pow((2),attempt),(voice_code.websocket.max_reconnect_delay_ms / (1000)));
var jitter_range = (base_delay * 0.25);
var jitter = (((cljs.core.rand.cljs$core$IFn$_invoke$arity$0() * jitter_range) * (2)) - jitter_range);
return cljs.core.max.cljs$core$IFn$_invoke$arity$2((1000),((1000) * (base_delay + jitter)));
});
/**
 * Start sending periodic ping messages.
 */
voice_code.websocket.start_ping_timer_BANG_ = (function voice_code$websocket$start_ping_timer_BANG_(){
if(cljs.core.truth_(cljs.core.deref(voice_code.websocket.ping_timer))){
clearInterval(cljs.core.deref(voice_code.websocket.ping_timer));
} else {
}

return cljs.core.reset_BANG_(voice_code.websocket.ping_timer,setInterval((function (){
var temp__5823__auto__ = cljs.core.deref(voice_code.websocket.ws_atom);
if(cljs.core.truth_(temp__5823__auto__)){
var ws = temp__5823__auto__;
if(cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(ws.readyState,(1))){
return ws.send(voice_code.json.clj__GT_json(new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"type","type",1174270348),"ping"], null)));
} else {
return null;
}
} else {
return null;
}
}),voice_code.websocket.ping_interval_ms));
});
/**
 * Stop sending ping messages.
 */
voice_code.websocket.stop_ping_timer_BANG_ = (function voice_code$websocket$stop_ping_timer_BANG_(){
if(cljs.core.truth_(cljs.core.deref(voice_code.websocket.ping_timer))){
clearInterval(cljs.core.deref(voice_code.websocket.ping_timer));

return cljs.core.reset_BANG_(voice_code.websocket.ping_timer,null);
} else {
return null;
}
});
/**
 * Send a message over the WebSocket connection.
 */
voice_code.websocket.send_message_BANG_ = (function voice_code$websocket$send_message_BANG_(msg){
var temp__5823__auto__ = cljs.core.deref(voice_code.websocket.ws_atom);
if(cljs.core.truth_(temp__5823__auto__)){
var ws = temp__5823__auto__;
if(cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(ws.readyState,(1))){
return ws.send(voice_code.json.clj__GT_json(msg));
} else {
return null;
}
} else {
return null;
}
});
/**
 * Close the WebSocket connection.
 */
voice_code.websocket.disconnect_BANG_ = (function voice_code$websocket$disconnect_BANG_(){
voice_code.websocket.stop_ping_timer_BANG_();

if(cljs.core.truth_(cljs.core.deref(voice_code.websocket.reconnect_timer))){
clearTimeout(cljs.core.deref(voice_code.websocket.reconnect_timer));

cljs.core.reset_BANG_(voice_code.websocket.reconnect_timer,null);
} else {
}

var temp__5823__auto__ = cljs.core.deref(voice_code.websocket.ws_atom);
if(cljs.core.truth_(temp__5823__auto__)){
var ws = temp__5823__auto__;
ws.close();

return cljs.core.reset_BANG_(voice_code.websocket.ws_atom,null);
} else {
return null;
}
});
/**
 * Establish a WebSocket connection to the backend.
 */
voice_code.websocket.connect_BANG_ = (function voice_code$websocket$connect_BANG_(p__12057){
var map__12060 = p__12057;
var map__12060__$1 = cljs.core.__destructure_map(map__12060);
var server_url = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__12060__$1,new cljs.core.Keyword(null,"server-url","server-url",1982223374));
var server_port = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__12060__$1,new cljs.core.Keyword(null,"server-port","server-port",663745648));
voice_code.websocket.disconnect_BANG_();

var url = (""+"ws://"+cljs.core.str.cljs$core$IFn$_invoke$arity$1(server_url)+":"+cljs.core.str.cljs$core$IFn$_invoke$arity$1(server_port)+"/ws");
var ws = (new WebSocket(url));
(ws.onopen = (function (_){
return re_frame.core.dispatch(new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","connected","ws/connected",-169836913)], null));
}));

(ws.onmessage = (function (event){
var temp__5823__auto__ = voice_code.json.parse_json_safe(event.data);
if(cljs.core.truth_(temp__5823__auto__)){
var msg = temp__5823__auto__;
return re_frame.core.dispatch(new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","message-received","ws/message-received",287223475),msg], null));
} else {
return null;
}
}));

(ws.onclose = (function (event){
return re_frame.core.dispatch(new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","disconnected","ws/disconnected",-1908000542),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"code","code",1586293142),event.code,new cljs.core.Keyword(null,"reason","reason",-2070751759),event.reason], null)], null));
}));

(ws.onerror = (function (error){
return re_frame.core.dispatch(new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword("ws","error","ws/error",-978964716),error], null));
}));

return cljs.core.reset_BANG_(voice_code.websocket.ws_atom,ws);
});
re_frame.core.reg_fx(new cljs.core.Keyword("ws","connect","ws/connect",1232825645),(function (config){
return voice_code.websocket.connect_BANG_(config);
}));
re_frame.core.reg_fx(new cljs.core.Keyword("ws","disconnect","ws/disconnect",-131970725),(function (_){
return voice_code.websocket.disconnect_BANG_();
}));
re_frame.core.reg_fx(new cljs.core.Keyword("ws","send","ws/send",-652154486),(function (msg){
return voice_code.websocket.send_message_BANG_(msg);
}));
re_frame.core.reg_fx(new cljs.core.Keyword("ws","start-ping-timer","ws/start-ping-timer",-1059944181),(function (_){
return voice_code.websocket.start_ping_timer_BANG_();
}));
re_frame.core.reg_fx(new cljs.core.Keyword("ws","stop-ping-timer","ws/stop-ping-timer",-389980801),(function (_){
return voice_code.websocket.stop_ping_timer_BANG_();
}));
re_frame.core.reg_fx(new cljs.core.Keyword("ws","schedule-reconnect","ws/schedule-reconnect",1843305927),(function (p__12093){
var map__12094 = p__12093;
var map__12094__$1 = cljs.core.__destructure_map(map__12094);
var delay_ms = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__12094__$1,new cljs.core.Keyword(null,"delay-ms","delay-ms",-59253516));
var config = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__12094__$1,new cljs.core.Keyword(null,"config","config",994861415));
if(cljs.core.truth_(cljs.core.deref(voice_code.websocket.reconnect_timer))){
clearTimeout(cljs.core.deref(voice_code.websocket.reconnect_timer));
} else {
}

return cljs.core.reset_BANG_(voice_code.websocket.reconnect_timer,setTimeout((function (){
return voice_code.websocket.connect_BANG_(config);
}),delay_ms));
}));

//# sourceMappingURL=voice_code.websocket.js.map
