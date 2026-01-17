goog.provide('voice_code.db');
/**
 * Initial application state.
 */
voice_code.db.default_db = cljs.core.PersistentHashMap.fromArrays([new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880),new cljs.core.Keyword(null,"settings","settings",1556144875),new cljs.core.Keyword(null,"recipes","recipes",-325236209),new cljs.core.Keyword(null,"ios-session-id","ios-session-id",1674306223),new cljs.core.Keyword(null,"commands","commands",161008658),new cljs.core.Keyword(null,"messages","messages",345434482),new cljs.core.Keyword(null,"ui","ui",-469653645),new cljs.core.Keyword(null,"active-session-id","active-session-id",943086451),new cljs.core.Keyword(null,"sessions","sessions",-699316392),new cljs.core.Keyword(null,"resources","resources",1632806811),new cljs.core.Keyword(null,"connection","connection",-123599300)],[cljs.core.PersistentHashSet.EMPTY,new cljs.core.PersistentArrayMap(null, 5, [new cljs.core.Keyword(null,"server-url","server-url",1982223374),"localhost",new cljs.core.Keyword(null,"server-port","server-port",663745648),(3000),new cljs.core.Keyword(null,"voice-identifier","voice-identifier",-1099793016),null,new cljs.core.Keyword(null,"recent-sessions-limit","recent-sessions-limit",560228192),(10),new cljs.core.Keyword(null,"max-message-size-kb","max-message-size-kb",524955570),(200)], null),new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"available","available",-1470697127),cljs.core.PersistentVector.EMPTY,new cljs.core.Keyword(null,"active","active",1895962068),cljs.core.PersistentArrayMap.EMPTY], null),null,new cljs.core.PersistentArrayMap(null, 3, [new cljs.core.Keyword(null,"available","available",-1470697127),cljs.core.PersistentArrayMap.EMPTY,new cljs.core.Keyword(null,"running","running",1554969103),cljs.core.PersistentArrayMap.EMPTY,new cljs.core.Keyword(null,"history","history",-247395220),cljs.core.PersistentVector.EMPTY], null),cljs.core.PersistentArrayMap.EMPTY,new cljs.core.PersistentArrayMap(null, 3, [new cljs.core.Keyword(null,"loading?","loading?",1905707049),false,new cljs.core.Keyword(null,"current-error","current-error",1366495244),null,new cljs.core.Keyword(null,"drafts","drafts",1523624562),cljs.core.PersistentArrayMap.EMPTY], null),null,cljs.core.PersistentArrayMap.EMPTY,new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"list","list",765357683),cljs.core.PersistentVector.EMPTY,new cljs.core.Keyword(null,"pending-uploads","pending-uploads",314048169),(0)], null),new cljs.core.PersistentArrayMap(null, 4, [new cljs.core.Keyword(null,"status","status",-1997798413),new cljs.core.Keyword(null,"disconnected","disconnected",-1908014586),new cljs.core.Keyword(null,"authenticated?","authenticated?",-1988130123),false,new cljs.core.Keyword(null,"error","error",-978969032),null,new cljs.core.Keyword(null,"reconnect-attempts","reconnect-attempts",-1994972943),(0)], null)]);
/**
 * Check if a session is currently locked (processing a prompt).
 */
voice_code.db.session_locked_QMARK_ = (function voice_code$db$session_locked_QMARK_(db,session_id){
return cljs.core.contains_QMARK_(new cljs.core.Keyword(null,"locked-sessions","locked-sessions",-1354550880).cljs$core$IFn$_invoke$arity$1(db),session_id);
});
/**
 * Get all messages for a session in chronological order.
 */
voice_code.db.get_messages_for_session = (function voice_code$db$get_messages_for_session(db,session_id){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$3(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"messages","messages",345434482),session_id], null),cljs.core.PersistentVector.EMPTY);
});
/**
 * Get session by ID.
 */
voice_code.db.get_session = (function voice_code$db$get_session(db,session_id){
return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(db,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"sessions","sessions",-699316392),session_id], null));
});
/**
 * Get the currently active session.
 */
voice_code.db.active_session = (function voice_code$db$active_session(db){
var temp__5823__auto__ = new cljs.core.Keyword(null,"active-session-id","active-session-id",943086451).cljs$core$IFn$_invoke$arity$1(db);
if(cljs.core.truth_(temp__5823__auto__)){
var id = temp__5823__auto__;
return voice_code.db.get_session(db,id);
} else {
return null;
}
});

//# sourceMappingURL=voice_code.db.js.map
