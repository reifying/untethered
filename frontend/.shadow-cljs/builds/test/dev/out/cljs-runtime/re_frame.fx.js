goog.provide('re_frame.fx');
re_frame.fx.kind = new cljs.core.Keyword(null,"fx","fx",-1237829572);
if(cljs.core.truth_((re_frame.registrar.kinds.cljs$core$IFn$_invoke$arity$1 ? re_frame.registrar.kinds.cljs$core$IFn$_invoke$arity$1(re_frame.fx.kind) : re_frame.registrar.kinds.call(null,re_frame.fx.kind)))){
} else {
throw (new Error("Assert failed: (re-frame.registrar/kinds kind)"));
}
re_frame.fx.reg_fx = (function re_frame$fx$reg_fx(id,handler){
return re_frame.registrar.register_handler(re_frame.fx.kind,id,handler);
});
/**
 * An interceptor whose `:after` actions the contents of `:effects`. As a result,
 *   this interceptor is Domino 3.
 * 
 *   This interceptor is silently added (by reg-event-db etc) to the front of
 *   interceptor chains for all events.
 * 
 *   For each key in `:effects` (a map), it calls the registered `effects handler`
 *   (see `reg-fx` for registration of effect handlers).
 * 
 *   So, if `:effects` was:
 *    {:dispatch  [:hello 42]
 *     :db        {...}
 *     :undo      "set flag"}
 * 
 *   it will call the registered effect handlers for each of the map's keys:
 *   `:dispatch`, `:undo` and `:db`. When calling each handler, provides the map
 *   value for that key - so in the example above the effect handler for :dispatch
 *   will be given one arg `[:hello 42]`.
 * 
 *   You cannot rely on the ordering in which effects are executed, other than that
 *   `:db` is guaranteed to be executed first.
 */
re_frame.fx.do_fx = re_frame.interceptor.__GT_interceptor.cljs$core$IFn$_invoke$arity$variadic(cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"id","id",-1388402092),new cljs.core.Keyword(null,"do-fx","do-fx",1194163050),new cljs.core.Keyword(null,"after","after",594996914),(function re_frame$fx$do_fx_after(context){
if(re_frame.trace.is_trace_enabled_QMARK_()){
var _STAR_current_trace_STAR__orig_val__11045 = re_frame.trace._STAR_current_trace_STAR_;
var _STAR_current_trace_STAR__temp_val__11046 = re_frame.trace.start_trace(new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"op-type","op-type",-1636141668),new cljs.core.Keyword("event","do-fx","event/do-fx",1357330452)], null));
(re_frame.trace._STAR_current_trace_STAR_ = _STAR_current_trace_STAR__temp_val__11046);

try{try{var effects = new cljs.core.Keyword(null,"effects","effects",-282369292).cljs$core$IFn$_invoke$arity$1(context);
var effects_without_db = cljs.core.dissoc.cljs$core$IFn$_invoke$arity$2(effects,new cljs.core.Keyword(null,"db","db",993250759));
var temp__5823__auto___11226 = new cljs.core.Keyword(null,"db","db",993250759).cljs$core$IFn$_invoke$arity$1(effects);
if(cljs.core.truth_(temp__5823__auto___11226)){
var new_db_11228 = temp__5823__auto___11226;
var fexpr__11054_11229 = re_frame.registrar.get_handler.cljs$core$IFn$_invoke$arity$3(re_frame.fx.kind,new cljs.core.Keyword(null,"db","db",993250759),false);
(fexpr__11054_11229.cljs$core$IFn$_invoke$arity$1 ? fexpr__11054_11229.cljs$core$IFn$_invoke$arity$1(new_db_11228) : fexpr__11054_11229.call(null,new_db_11228));
} else {
}

var seq__11058 = cljs.core.seq(effects_without_db);
var chunk__11059 = null;
var count__11060 = (0);
var i__11061 = (0);
while(true){
if((i__11061 < count__11060)){
var vec__11097 = chunk__11059.cljs$core$IIndexed$_nth$arity$2(null,i__11061);
var effect_key = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11097,(0),null);
var effect_value = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11097,(1),null);
var temp__5821__auto___11232 = re_frame.registrar.get_handler.cljs$core$IFn$_invoke$arity$3(re_frame.fx.kind,effect_key,false);
if(cljs.core.truth_(temp__5821__auto___11232)){
var effect_fn_11233 = temp__5821__auto___11232;
(effect_fn_11233.cljs$core$IFn$_invoke$arity$1 ? effect_fn_11233.cljs$core$IFn$_invoke$arity$1(effect_value) : effect_fn_11233.call(null,effect_value));
} else {
re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: no handler registered for effect:",effect_key,". Ignoring.",((cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"event","event",301435442),effect_key))?(""+"You may be trying to return a coeffect map from an event-fx handler. "+"See https://day8.github.io/re-frame/use-cofx-as-fx/"):null)], 0));
}


var G__11234 = seq__11058;
var G__11235 = chunk__11059;
var G__11236 = count__11060;
var G__11237 = (i__11061 + (1));
seq__11058 = G__11234;
chunk__11059 = G__11235;
count__11060 = G__11236;
i__11061 = G__11237;
continue;
} else {
var temp__5823__auto__ = cljs.core.seq(seq__11058);
if(temp__5823__auto__){
var seq__11058__$1 = temp__5823__auto__;
if(cljs.core.chunked_seq_QMARK_(seq__11058__$1)){
var c__5673__auto__ = cljs.core.chunk_first(seq__11058__$1);
var G__11238 = cljs.core.chunk_rest(seq__11058__$1);
var G__11239 = c__5673__auto__;
var G__11240 = cljs.core.count(c__5673__auto__);
var G__11241 = (0);
seq__11058 = G__11238;
chunk__11059 = G__11239;
count__11060 = G__11240;
i__11061 = G__11241;
continue;
} else {
var vec__11105 = cljs.core.first(seq__11058__$1);
var effect_key = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11105,(0),null);
var effect_value = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11105,(1),null);
var temp__5821__auto___11242 = re_frame.registrar.get_handler.cljs$core$IFn$_invoke$arity$3(re_frame.fx.kind,effect_key,false);
if(cljs.core.truth_(temp__5821__auto___11242)){
var effect_fn_11243 = temp__5821__auto___11242;
(effect_fn_11243.cljs$core$IFn$_invoke$arity$1 ? effect_fn_11243.cljs$core$IFn$_invoke$arity$1(effect_value) : effect_fn_11243.call(null,effect_value));
} else {
re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: no handler registered for effect:",effect_key,". Ignoring.",((cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"event","event",301435442),effect_key))?(""+"You may be trying to return a coeffect map from an event-fx handler. "+"See https://day8.github.io/re-frame/use-cofx-as-fx/"):null)], 0));
}


var G__11246 = cljs.core.next(seq__11058__$1);
var G__11247 = null;
var G__11248 = (0);
var G__11249 = (0);
seq__11058 = G__11246;
chunk__11059 = G__11247;
count__11060 = G__11248;
i__11061 = G__11249;
continue;
}
} else {
return null;
}
}
break;
}
}finally {if(re_frame.trace.is_trace_enabled_QMARK_()){
var end__10158__auto___11250 = re_frame.interop.now();
var duration__10159__auto___11251 = (end__10158__auto___11250 - new cljs.core.Keyword(null,"start","start",-355208981).cljs$core$IFn$_invoke$arity$1(re_frame.trace._STAR_current_trace_STAR_));
cljs.core.swap_BANG_.cljs$core$IFn$_invoke$arity$3(re_frame.trace.traces,cljs.core.conj,cljs.core.assoc.cljs$core$IFn$_invoke$arity$variadic(re_frame.trace._STAR_current_trace_STAR_,new cljs.core.Keyword(null,"duration","duration",1444101068),duration__10159__auto___11251,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"end","end",-268185958),re_frame.interop.now()], 0)));

re_frame.trace.run_tracing_callbacks_BANG_(end__10158__auto___11250);
} else {
}
}}finally {(re_frame.trace._STAR_current_trace_STAR_ = _STAR_current_trace_STAR__orig_val__11045);
}} else {
var effects = new cljs.core.Keyword(null,"effects","effects",-282369292).cljs$core$IFn$_invoke$arity$1(context);
var effects_without_db = cljs.core.dissoc.cljs$core$IFn$_invoke$arity$2(effects,new cljs.core.Keyword(null,"db","db",993250759));
var temp__5823__auto___11254 = new cljs.core.Keyword(null,"db","db",993250759).cljs$core$IFn$_invoke$arity$1(effects);
if(cljs.core.truth_(temp__5823__auto___11254)){
var new_db_11255 = temp__5823__auto___11254;
var fexpr__11111_11257 = re_frame.registrar.get_handler.cljs$core$IFn$_invoke$arity$3(re_frame.fx.kind,new cljs.core.Keyword(null,"db","db",993250759),false);
(fexpr__11111_11257.cljs$core$IFn$_invoke$arity$1 ? fexpr__11111_11257.cljs$core$IFn$_invoke$arity$1(new_db_11255) : fexpr__11111_11257.call(null,new_db_11255));
} else {
}

var seq__11112 = cljs.core.seq(effects_without_db);
var chunk__11113 = null;
var count__11114 = (0);
var i__11115 = (0);
while(true){
if((i__11115 < count__11114)){
var vec__11124 = chunk__11113.cljs$core$IIndexed$_nth$arity$2(null,i__11115);
var effect_key = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11124,(0),null);
var effect_value = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11124,(1),null);
var temp__5821__auto___11259 = re_frame.registrar.get_handler.cljs$core$IFn$_invoke$arity$3(re_frame.fx.kind,effect_key,false);
if(cljs.core.truth_(temp__5821__auto___11259)){
var effect_fn_11260 = temp__5821__auto___11259;
(effect_fn_11260.cljs$core$IFn$_invoke$arity$1 ? effect_fn_11260.cljs$core$IFn$_invoke$arity$1(effect_value) : effect_fn_11260.call(null,effect_value));
} else {
re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: no handler registered for effect:",effect_key,". Ignoring.",((cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"event","event",301435442),effect_key))?(""+"You may be trying to return a coeffect map from an event-fx handler. "+"See https://day8.github.io/re-frame/use-cofx-as-fx/"):null)], 0));
}


var G__11261 = seq__11112;
var G__11262 = chunk__11113;
var G__11263 = count__11114;
var G__11264 = (i__11115 + (1));
seq__11112 = G__11261;
chunk__11113 = G__11262;
count__11114 = G__11263;
i__11115 = G__11264;
continue;
} else {
var temp__5823__auto__ = cljs.core.seq(seq__11112);
if(temp__5823__auto__){
var seq__11112__$1 = temp__5823__auto__;
if(cljs.core.chunked_seq_QMARK_(seq__11112__$1)){
var c__5673__auto__ = cljs.core.chunk_first(seq__11112__$1);
var G__11265 = cljs.core.chunk_rest(seq__11112__$1);
var G__11266 = c__5673__auto__;
var G__11267 = cljs.core.count(c__5673__auto__);
var G__11268 = (0);
seq__11112 = G__11265;
chunk__11113 = G__11266;
count__11114 = G__11267;
i__11115 = G__11268;
continue;
} else {
var vec__11129 = cljs.core.first(seq__11112__$1);
var effect_key = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11129,(0),null);
var effect_value = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11129,(1),null);
var temp__5821__auto___11273 = re_frame.registrar.get_handler.cljs$core$IFn$_invoke$arity$3(re_frame.fx.kind,effect_key,false);
if(cljs.core.truth_(temp__5821__auto___11273)){
var effect_fn_11278 = temp__5821__auto___11273;
(effect_fn_11278.cljs$core$IFn$_invoke$arity$1 ? effect_fn_11278.cljs$core$IFn$_invoke$arity$1(effect_value) : effect_fn_11278.call(null,effect_value));
} else {
re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: no handler registered for effect:",effect_key,". Ignoring.",((cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"event","event",301435442),effect_key))?(""+"You may be trying to return a coeffect map from an event-fx handler. "+"See https://day8.github.io/re-frame/use-cofx-as-fx/"):null)], 0));
}


var G__11279 = cljs.core.next(seq__11112__$1);
var G__11280 = null;
var G__11281 = (0);
var G__11282 = (0);
seq__11112 = G__11279;
chunk__11113 = G__11280;
count__11114 = G__11281;
i__11115 = G__11282;
continue;
}
} else {
return null;
}
}
break;
}
}
})], 0));
re_frame.fx.dispatch_later = (function re_frame$fx$dispatch_later(p__11140){
var map__11141 = p__11140;
var map__11141__$1 = cljs.core.__destructure_map(map__11141);
var effect = map__11141__$1;
var ms = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11141__$1,new cljs.core.Keyword(null,"ms","ms",-1152709733));
var dispatch = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11141__$1,new cljs.core.Keyword(null,"dispatch","dispatch",1319337009));
if(((cljs.core.empty_QMARK_(dispatch)) || ((!(typeof ms === 'number'))))){
return re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"error","error",-978969032),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: ignoring bad :dispatch-later value:",effect], 0));
} else {
return re_frame.interop.set_timeout_BANG_((function (){
return re_frame.router.dispatch(dispatch);
}),ms);
}
});
re_frame.fx.reg_fx(new cljs.core.Keyword(null,"dispatch-later","dispatch-later",291951390),(function (value){
if(cljs.core.map_QMARK_(value)){
return re_frame.fx.dispatch_later(value);
} else {
var seq__11144 = cljs.core.seq(cljs.core.remove.cljs$core$IFn$_invoke$arity$2(cljs.core.nil_QMARK_,value));
var chunk__11145 = null;
var count__11146 = (0);
var i__11147 = (0);
while(true){
if((i__11147 < count__11146)){
var effect = chunk__11145.cljs$core$IIndexed$_nth$arity$2(null,i__11147);
re_frame.fx.dispatch_later(effect);


var G__11291 = seq__11144;
var G__11292 = chunk__11145;
var G__11293 = count__11146;
var G__11294 = (i__11147 + (1));
seq__11144 = G__11291;
chunk__11145 = G__11292;
count__11146 = G__11293;
i__11147 = G__11294;
continue;
} else {
var temp__5823__auto__ = cljs.core.seq(seq__11144);
if(temp__5823__auto__){
var seq__11144__$1 = temp__5823__auto__;
if(cljs.core.chunked_seq_QMARK_(seq__11144__$1)){
var c__5673__auto__ = cljs.core.chunk_first(seq__11144__$1);
var G__11297 = cljs.core.chunk_rest(seq__11144__$1);
var G__11298 = c__5673__auto__;
var G__11299 = cljs.core.count(c__5673__auto__);
var G__11300 = (0);
seq__11144 = G__11297;
chunk__11145 = G__11298;
count__11146 = G__11299;
i__11147 = G__11300;
continue;
} else {
var effect = cljs.core.first(seq__11144__$1);
re_frame.fx.dispatch_later(effect);


var G__11301 = cljs.core.next(seq__11144__$1);
var G__11302 = null;
var G__11303 = (0);
var G__11304 = (0);
seq__11144 = G__11301;
chunk__11145 = G__11302;
count__11146 = G__11303;
i__11147 = G__11304;
continue;
}
} else {
return null;
}
}
break;
}
}
}));
re_frame.fx.reg_fx(new cljs.core.Keyword(null,"fx","fx",-1237829572),(function (seq_of_effects){
if((!(cljs.core.sequential_QMARK_(seq_of_effects)))){
return re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: \":fx\" effect expects a seq, but was given ",cljs.core.type(seq_of_effects)], 0));
} else {
var seq__11172 = cljs.core.seq(cljs.core.remove.cljs$core$IFn$_invoke$arity$2(cljs.core.nil_QMARK_,seq_of_effects));
var chunk__11173 = null;
var count__11174 = (0);
var i__11175 = (0);
while(true){
if((i__11175 < count__11174)){
var vec__11188 = chunk__11173.cljs$core$IIndexed$_nth$arity$2(null,i__11175);
var effect_key = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11188,(0),null);
var effect_value = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11188,(1),null);
if(cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"db","db",993250759),effect_key)){
re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: \":fx\" effect should not contain a :db effect"], 0));
} else {
}

var temp__5821__auto___11308 = re_frame.registrar.get_handler.cljs$core$IFn$_invoke$arity$3(re_frame.fx.kind,effect_key,false);
if(cljs.core.truth_(temp__5821__auto___11308)){
var effect_fn_11309 = temp__5821__auto___11308;
(effect_fn_11309.cljs$core$IFn$_invoke$arity$1 ? effect_fn_11309.cljs$core$IFn$_invoke$arity$1(effect_value) : effect_fn_11309.call(null,effect_value));
} else {
re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: in \":fx\" effect found ",effect_key," which has no associated handler. Ignoring."], 0));
}


var G__11310 = seq__11172;
var G__11311 = chunk__11173;
var G__11312 = count__11174;
var G__11313 = (i__11175 + (1));
seq__11172 = G__11310;
chunk__11173 = G__11311;
count__11174 = G__11312;
i__11175 = G__11313;
continue;
} else {
var temp__5823__auto__ = cljs.core.seq(seq__11172);
if(temp__5823__auto__){
var seq__11172__$1 = temp__5823__auto__;
if(cljs.core.chunked_seq_QMARK_(seq__11172__$1)){
var c__5673__auto__ = cljs.core.chunk_first(seq__11172__$1);
var G__11314 = cljs.core.chunk_rest(seq__11172__$1);
var G__11315 = c__5673__auto__;
var G__11316 = cljs.core.count(c__5673__auto__);
var G__11317 = (0);
seq__11172 = G__11314;
chunk__11173 = G__11315;
count__11174 = G__11316;
i__11175 = G__11317;
continue;
} else {
var vec__11195 = cljs.core.first(seq__11172__$1);
var effect_key = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11195,(0),null);
var effect_value = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11195,(1),null);
if(cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"db","db",993250759),effect_key)){
re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: \":fx\" effect should not contain a :db effect"], 0));
} else {
}

var temp__5821__auto___11318 = re_frame.registrar.get_handler.cljs$core$IFn$_invoke$arity$3(re_frame.fx.kind,effect_key,false);
if(cljs.core.truth_(temp__5821__auto___11318)){
var effect_fn_11319 = temp__5821__auto___11318;
(effect_fn_11319.cljs$core$IFn$_invoke$arity$1 ? effect_fn_11319.cljs$core$IFn$_invoke$arity$1(effect_value) : effect_fn_11319.call(null,effect_value));
} else {
re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"warn","warn",-436710552),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: in \":fx\" effect found ",effect_key," which has no associated handler. Ignoring."], 0));
}


var G__11324 = cljs.core.next(seq__11172__$1);
var G__11325 = null;
var G__11326 = (0);
var G__11327 = (0);
seq__11172 = G__11324;
chunk__11173 = G__11325;
count__11174 = G__11326;
i__11175 = G__11327;
continue;
}
} else {
return null;
}
}
break;
}
}
}));
re_frame.fx.reg_fx(new cljs.core.Keyword(null,"dispatch","dispatch",1319337009),(function (value){
if((!(cljs.core.vector_QMARK_(value)))){
return re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"error","error",-978969032),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: ignoring bad :dispatch value. Expected a vector, but got:",value], 0));
} else {
return re_frame.router.dispatch(value);
}
}));
re_frame.fx.reg_fx(new cljs.core.Keyword(null,"dispatch-n","dispatch-n",-504469236),(function (value){
if((!(cljs.core.sequential_QMARK_(value)))){
return re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"error","error",-978969032),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: ignoring bad :dispatch-n value. Expected a collection, but got:",value], 0));
} else {
var seq__11200 = cljs.core.seq(cljs.core.remove.cljs$core$IFn$_invoke$arity$2(cljs.core.nil_QMARK_,value));
var chunk__11201 = null;
var count__11202 = (0);
var i__11203 = (0);
while(true){
if((i__11203 < count__11202)){
var event = chunk__11201.cljs$core$IIndexed$_nth$arity$2(null,i__11203);
re_frame.router.dispatch(event);


var G__11334 = seq__11200;
var G__11335 = chunk__11201;
var G__11336 = count__11202;
var G__11337 = (i__11203 + (1));
seq__11200 = G__11334;
chunk__11201 = G__11335;
count__11202 = G__11336;
i__11203 = G__11337;
continue;
} else {
var temp__5823__auto__ = cljs.core.seq(seq__11200);
if(temp__5823__auto__){
var seq__11200__$1 = temp__5823__auto__;
if(cljs.core.chunked_seq_QMARK_(seq__11200__$1)){
var c__5673__auto__ = cljs.core.chunk_first(seq__11200__$1);
var G__11340 = cljs.core.chunk_rest(seq__11200__$1);
var G__11341 = c__5673__auto__;
var G__11342 = cljs.core.count(c__5673__auto__);
var G__11343 = (0);
seq__11200 = G__11340;
chunk__11201 = G__11341;
count__11202 = G__11342;
i__11203 = G__11343;
continue;
} else {
var event = cljs.core.first(seq__11200__$1);
re_frame.router.dispatch(event);


var G__11344 = cljs.core.next(seq__11200__$1);
var G__11345 = null;
var G__11346 = (0);
var G__11347 = (0);
seq__11200 = G__11344;
chunk__11201 = G__11345;
count__11202 = G__11346;
i__11203 = G__11347;
continue;
}
} else {
return null;
}
}
break;
}
}
}));
re_frame.fx.reg_fx(new cljs.core.Keyword(null,"deregister-event-handler","deregister-event-handler",-1096518994),(function (value){
var clear_event = cljs.core.partial.cljs$core$IFn$_invoke$arity$2(re_frame.registrar.clear_handlers,re_frame.events.kind);
if(cljs.core.sequential_QMARK_(value)){
var seq__11206 = cljs.core.seq(value);
var chunk__11207 = null;
var count__11208 = (0);
var i__11209 = (0);
while(true){
if((i__11209 < count__11208)){
var event = chunk__11207.cljs$core$IIndexed$_nth$arity$2(null,i__11209);
clear_event(event);


var G__11351 = seq__11206;
var G__11352 = chunk__11207;
var G__11353 = count__11208;
var G__11354 = (i__11209 + (1));
seq__11206 = G__11351;
chunk__11207 = G__11352;
count__11208 = G__11353;
i__11209 = G__11354;
continue;
} else {
var temp__5823__auto__ = cljs.core.seq(seq__11206);
if(temp__5823__auto__){
var seq__11206__$1 = temp__5823__auto__;
if(cljs.core.chunked_seq_QMARK_(seq__11206__$1)){
var c__5673__auto__ = cljs.core.chunk_first(seq__11206__$1);
var G__11355 = cljs.core.chunk_rest(seq__11206__$1);
var G__11356 = c__5673__auto__;
var G__11357 = cljs.core.count(c__5673__auto__);
var G__11358 = (0);
seq__11206 = G__11355;
chunk__11207 = G__11356;
count__11208 = G__11357;
i__11209 = G__11358;
continue;
} else {
var event = cljs.core.first(seq__11206__$1);
clear_event(event);


var G__11363 = cljs.core.next(seq__11206__$1);
var G__11364 = null;
var G__11365 = (0);
var G__11366 = (0);
seq__11206 = G__11363;
chunk__11207 = G__11364;
count__11208 = G__11365;
i__11209 = G__11366;
continue;
}
} else {
return null;
}
}
break;
}
} else {
return clear_event(value);
}
}));
re_frame.fx.reg_fx(new cljs.core.Keyword(null,"db","db",993250759),(function (value){
if((!((cljs.core.deref(re_frame.db.app_db) === value)))){
return cljs.core.reset_BANG_(re_frame.db.app_db,value);
} else {
if(re_frame.trace.is_trace_enabled_QMARK_()){
var _STAR_current_trace_STAR__orig_val__11222 = re_frame.trace._STAR_current_trace_STAR_;
var _STAR_current_trace_STAR__temp_val__11223 = re_frame.trace.start_trace(new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"op-type","op-type",-1636141668),new cljs.core.Keyword("reagent","quiescent","reagent/quiescent",-16138681)], null));
(re_frame.trace._STAR_current_trace_STAR_ = _STAR_current_trace_STAR__temp_val__11223);

try{try{return null;
}finally {if(re_frame.trace.is_trace_enabled_QMARK_()){
var end__10158__auto___11369 = re_frame.interop.now();
var duration__10159__auto___11371 = (end__10158__auto___11369 - new cljs.core.Keyword(null,"start","start",-355208981).cljs$core$IFn$_invoke$arity$1(re_frame.trace._STAR_current_trace_STAR_));
cljs.core.swap_BANG_.cljs$core$IFn$_invoke$arity$3(re_frame.trace.traces,cljs.core.conj,cljs.core.assoc.cljs$core$IFn$_invoke$arity$variadic(re_frame.trace._STAR_current_trace_STAR_,new cljs.core.Keyword(null,"duration","duration",1444101068),duration__10159__auto___11371,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"end","end",-268185958),re_frame.interop.now()], 0)));

re_frame.trace.run_tracing_callbacks_BANG_(end__10158__auto___11369);
} else {
}
}}finally {(re_frame.trace._STAR_current_trace_STAR_ = _STAR_current_trace_STAR__orig_val__11222);
}} else {
return null;
}
}
}));

//# sourceMappingURL=re_frame.fx.js.map
