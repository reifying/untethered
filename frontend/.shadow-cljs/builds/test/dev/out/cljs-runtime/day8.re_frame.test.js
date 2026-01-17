goog.provide('day8.re_frame.test');
/**
 * Dequeue an item from a persistent queue which is stored as the value in
 *   queue-atom. Returns the item, and updates the atom with the new queue
 *   value. If the queue is empty, does not alter it and returns nil.
 */
day8.re_frame.test.dequeue_BANG_ = (function day8$re_frame$test$dequeue_BANG_(queue_atom){
while(true){
var queue = cljs.core.deref(queue_atom);
if(cljs.core.seq(queue)){
if(cljs.core.compare_and_set_BANG_(queue_atom,queue,cljs.core.pop(queue))){
return cljs.core.peek(queue);
} else {
var G__13506 = queue_atom;
queue_atom = G__13506;
continue;
}
} else {
return null;
}
break;
}
});
day8.re_frame.test._STAR_test_timeout_STAR_ = (5000);
/**
 * `*test-context*` is used to communicate internal details of the test between
 *   `run-test-async*` and `wait-for*`. It is dynamically bound so that it doesn't
 *   need to appear as a lexical argument to a `wait-for` block, since we don't
 *   want it to be visible when you're writing tests.  But care must be taken to
 *   pass it around lexically across callbacks, since ClojureScript doesn't have
 *   `bound-fn`.
 */
day8.re_frame.test._STAR_test_context_STAR_ = null;

/**
* @constructor
 * @implements {cljs.core.IFn}
 * @implements {cljs.core.IMeta}
 * @implements {cljs.test.IAsyncTest}
 * @implements {cljs.core.IWithMeta}
*/
day8.re_frame.test.t_day8$re_frame$test13402 = (function (f,test_context,meta13403){
this.f = f;
this.test_context = test_context;
this.meta13403 = meta13403;
this.cljs$lang$protocol_mask$partition0$ = 393217;
this.cljs$lang$protocol_mask$partition1$ = 0;
});
(day8.re_frame.test.t_day8$re_frame$test13402.prototype.cljs$core$IWithMeta$_with_meta$arity$2 = (function (_13404,meta13403__$1){
var self__ = this;
var _13404__$1 = this;
return (new day8.re_frame.test.t_day8$re_frame$test13402(self__.f,self__.test_context,meta13403__$1));
}));

(day8.re_frame.test.t_day8$re_frame$test13402.prototype.cljs$core$IMeta$_meta$arity$1 = (function (_13404){
var self__ = this;
var _13404__$1 = this;
return self__.meta13403;
}));

(day8.re_frame.test.t_day8$re_frame$test13402.prototype.cljs$test$IAsyncTest$ = cljs.core.PROTOCOL_SENTINEL);

(day8.re_frame.test.t_day8$re_frame$test13402.prototype.call = (function (unused__10370__auto__){
var self__ = this;
var self__ = this;
var G__13411 = (arguments.length - (1));
switch (G__13411) {
case (1):
return self__.cljs$core$IFn$_invoke$arity$1((arguments[(1)]));

break;
default:
throw (new Error((""+"Invalid arity: "+cljs.core.str.cljs$core$IFn$_invoke$arity$1((arguments.length - (1))))));

}
}));

(day8.re_frame.test.t_day8$re_frame$test13402.prototype.apply = (function (self__,args13406){
var self__ = this;
var self____$1 = this;
return self____$1.call.apply(self____$1,[self____$1].concat(cljs.core.aclone(args13406)));
}));

(day8.re_frame.test.t_day8$re_frame$test13402.prototype.cljs$core$IFn$_invoke$arity$1 = (function (done){
var self__ = this;
var ___10059__auto__ = this;
var restore_fn = re_frame.core.make_restore_fn();
var _STAR_test_context_STAR__orig_val__13418 = day8.re_frame.test._STAR_test_context_STAR_;
var _STAR_test_context_STAR__temp_val__13419 = cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(self__.test_context,new cljs.core.Keyword(null,"done","done",-889844188),(function (){
restore_fn();

return (done.cljs$core$IFn$_invoke$arity$0 ? done.cljs$core$IFn$_invoke$arity$0() : done.call(null));
}));
(day8.re_frame.test._STAR_test_context_STAR_ = _STAR_test_context_STAR__temp_val__13419);

try{return (self__.f.cljs$core$IFn$_invoke$arity$0 ? self__.f.cljs$core$IFn$_invoke$arity$0() : self__.f.call(null));
}finally {(day8.re_frame.test._STAR_test_context_STAR_ = _STAR_test_context_STAR__orig_val__13418);
}}));

(day8.re_frame.test.t_day8$re_frame$test13402.getBasis = (function (){
return new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Symbol(null,"f","f",43394975,null),new cljs.core.Symbol(null,"test-context","test-context",-2049932830,null),new cljs.core.Symbol(null,"meta13403","meta13403",1564401901,null)], null);
}));

(day8.re_frame.test.t_day8$re_frame$test13402.cljs$lang$type = true);

(day8.re_frame.test.t_day8$re_frame$test13402.cljs$lang$ctorStr = "day8.re-frame.test/t_day8$re_frame$test13402");

(day8.re_frame.test.t_day8$re_frame$test13402.cljs$lang$ctorPrWriter = (function (this__5434__auto__,writer__5435__auto__,opt__5436__auto__){
return cljs.core._write(writer__5435__auto__,"day8.re-frame.test/t_day8$re_frame$test13402");
}));

/**
 * Positional factory function for day8.re-frame.test/t_day8$re_frame$test13402.
 */
day8.re_frame.test.__GT_t_day8$re_frame$test13402 = (function day8$re_frame$test$__GT_t_day8$re_frame$test13402(f,test_context,meta13403){
return (new day8.re_frame.test.t_day8$re_frame$test13402(f,test_context,meta13403));
});


day8.re_frame.test.run_test_async_STAR_ = (function day8$re_frame$test$run_test_async_STAR_(f){
var test_context = new cljs.core.PersistentArrayMap(null, 3, [new cljs.core.Keyword(null,"wait-for-depth","wait-for-depth",-1366777331),(0),new cljs.core.Keyword(null,"max-wait-for-depth","max-wait-for-depth",639503457),cljs.core.atom.cljs$core$IFn$_invoke$arity$1((0)),new cljs.core.Keyword(null,"now-waiting-for","now-waiting-for",322402761),cljs.core.atom.cljs$core$IFn$_invoke$arity$1(null)], null);
return (new day8.re_frame.test.t_day8$re_frame$test13402(f,test_context,null));
});
/**
 * Interprets the acceptable input values for `wait-for`'s `ok-ids` and
 *   `failure-ids` params to produce a predicate function on an event.  See
 *   `wait-for` for details.
 */
day8.re_frame.test.as_callback_pred = (function day8$re_frame$test$as_callback_pred(callback_pred){
if(cljs.core.truth_(callback_pred)){
if(((cljs.core.set_QMARK_(callback_pred)) || (cljs.core.vector_QMARK_(callback_pred)))){
return (function (event){
return cljs.core.some((function (pred){
return (pred.cljs$core$IFn$_invoke$arity$1 ? pred.cljs$core$IFn$_invoke$arity$1(event) : pred.call(null,event));
}),cljs.core.map.cljs$core$IFn$_invoke$arity$2(day8.re_frame.test.as_callback_pred,cljs.core.seq(callback_pred)));
});
} else {
if(cljs.core.fn_QMARK_(callback_pred)){
return callback_pred;
} else {
if((callback_pred instanceof cljs.core.Keyword)){
return (function (p__13443){
var vec__13444 = p__13443;
var event_id = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13444,(0),null);
var _ = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__13444,(1),null);
return cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(callback_pred,event_id);
});
} else {
throw cljs.core.ex_info.cljs$core$IFn$_invoke$arity$2((""+cljs.core.str.cljs$core$IFn$_invoke$arity$1(cljs.core.pr_str.cljs$core$IFn$_invoke$arity$variadic(cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([callback_pred], 0)))+" isn't an event predicate"),new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"callback-pred","callback-pred",90867475),callback_pred], null));

}
}
}
} else {
return null;
}
});
/**
 * This function is an implementation detail: in your async tests (within a
 *   `run-test-async`), you should use the `wait-for` macro instead.  (For
 *   synchronous tests within `run-test-sync`, you don't need this capability at
 *   all.)
 * 
 *   Installs `callback` as a re-frame post-event callback handler, called as soon
 *   as any event matching `ok-ids` is handled.  Aborts the test as a failure if
 *   any event matching `failure-ids` is handled.
 * 
 *   Since this is intended for use in asynchronous tests: it will return
 *   immediately after installing the callback -- it doesn't *actually* wait.
 * 
 *   Note that `wait-for*` tracks whether, during your callback, you call
 *   `wait-for*` again.  If you *don't*, then, given the way asynchronous tests
 *   work, your test must necessarily be finished.  So `wait-for*` will
 *   call `(done)` for you.
 */
day8.re_frame.test.wait_for_STAR_ = (function day8$re_frame$test$wait_for_STAR_(ok_ids,failure_ids,callback){
var map__13454 = cljs.core.update.cljs$core$IFn$_invoke$arity$3(day8.re_frame.test._STAR_test_context_STAR_,new cljs.core.Keyword(null,"wait-for-depth","wait-for-depth",-1366777331),cljs.core.inc);
var map__13454__$1 = cljs.core.__destructure_map(map__13454);
var test_context = map__13454__$1;
var done = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__13454__$1,new cljs.core.Keyword(null,"done","done",-889844188));
cljs.core.swap_BANG_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"max-wait-for-depth","max-wait-for-depth",639503457).cljs$core$IFn$_invoke$arity$1(test_context),cljs.core.inc);

var ok_pred = day8.re_frame.test.as_callback_pred(ok_ids);
var fail_pred = day8.re_frame.test.as_callback_pred(failure_ids);
var cb_id = cljs.core.gensym.cljs$core$IFn$_invoke$arity$1("wait-for-cb-fn");
re_frame.core.add_post_event_callback.cljs$core$IFn$_invoke$arity$2(cb_id,(function (event,_){
if(cljs.core.truth_((function (){var and__5140__auto__ = fail_pred;
if(cljs.core.truth_(and__5140__auto__)){
return cljs.core.not((function (){try{var values__10011__auto__ = (new cljs.core.List(null,(fail_pred.cljs$core$IFn$_invoke$arity$1 ? fail_pred.cljs$core$IFn$_invoke$arity$1(event) : fail_pred.call(null,event)),null,(1),null));
var result__10012__auto__ = cljs.core.apply.cljs$core$IFn$_invoke$arity$2(cljs.core.not,values__10011__auto__);
if(cljs.core.truth_(result__10012__auto__)){
cljs.test.report.call(null,cljs.core.PersistentHashMap.fromArrays([new cljs.core.Keyword(null,"file","file",-1269645878),new cljs.core.Keyword(null,"end-column","end-column",1425389514),new cljs.core.Keyword(null,"type","type",1174270348),new cljs.core.Keyword(null,"column","column",2078222095),new cljs.core.Keyword(null,"line","line",212345235),new cljs.core.Keyword(null,"expected","expected",1583670997),new cljs.core.Keyword(null,"end-line","end-line",1837326455),new cljs.core.Keyword(null,"actual","actual",107306363),new cljs.core.Keyword(null,"message","message",-406056002)],["day8/re_frame/test.cljc",91,new cljs.core.Keyword(null,"pass","pass",1574159993),68,177,cljs.core.list(new cljs.core.Symbol(null,"not","not",1044554643,null),cljs.core.list(new cljs.core.Symbol(null,"fail-pred","fail-pred",518790579,null),new cljs.core.Symbol(null,"event","event",1941966969,null))),177,cljs.core.cons(new cljs.core.Symbol(null,"not","not",1044554643,null),values__10011__auto__),"Received failure event"]));
} else {
cljs.test.report.call(null,cljs.core.PersistentHashMap.fromArrays([new cljs.core.Keyword(null,"file","file",-1269645878),new cljs.core.Keyword(null,"end-column","end-column",1425389514),new cljs.core.Keyword(null,"type","type",1174270348),new cljs.core.Keyword(null,"column","column",2078222095),new cljs.core.Keyword(null,"line","line",212345235),new cljs.core.Keyword(null,"expected","expected",1583670997),new cljs.core.Keyword(null,"end-line","end-line",1837326455),new cljs.core.Keyword(null,"actual","actual",107306363),new cljs.core.Keyword(null,"message","message",-406056002)],["day8/re_frame/test.cljc",91,new cljs.core.Keyword(null,"fail","fail",1706214930),68,177,cljs.core.list(new cljs.core.Symbol(null,"not","not",1044554643,null),cljs.core.list(new cljs.core.Symbol(null,"fail-pred","fail-pred",518790579,null),new cljs.core.Symbol(null,"event","event",1941966969,null))),177,(new cljs.core.List(null,new cljs.core.Symbol(null,"not","not",1044554643,null),(new cljs.core.List(null,cljs.core.cons(new cljs.core.Symbol(null,"not","not",1044554643,null),values__10011__auto__),null,(1),null)),(2),null)),"Received failure event"]));
}

return result__10012__auto__;
}catch (e13459){var t__10048__auto__ = e13459;
return cljs.test.report.call(null,cljs.core.PersistentHashMap.fromArrays([new cljs.core.Keyword(null,"file","file",-1269645878),new cljs.core.Keyword(null,"end-column","end-column",1425389514),new cljs.core.Keyword(null,"type","type",1174270348),new cljs.core.Keyword(null,"column","column",2078222095),new cljs.core.Keyword(null,"line","line",212345235),new cljs.core.Keyword(null,"expected","expected",1583670997),new cljs.core.Keyword(null,"end-line","end-line",1837326455),new cljs.core.Keyword(null,"actual","actual",107306363),new cljs.core.Keyword(null,"message","message",-406056002)],["day8/re_frame/test.cljc",91,new cljs.core.Keyword(null,"error","error",-978969032),68,177,cljs.core.list(new cljs.core.Symbol(null,"not","not",1044554643,null),cljs.core.list(new cljs.core.Symbol(null,"fail-pred","fail-pred",518790579,null),new cljs.core.Symbol(null,"event","event",1941966969,null))),177,t__10048__auto__,"Received failure event"]));
}})());
} else {
return and__5140__auto__;
}
})())){
re_frame.core.remove_post_event_callback(cb_id);

cljs.core.reset_BANG_(new cljs.core.Keyword(null,"now-waiting-for","now-waiting-for",322402761).cljs$core$IFn$_invoke$arity$1(test_context),null);

return (done.cljs$core$IFn$_invoke$arity$0 ? done.cljs$core$IFn$_invoke$arity$0() : done.call(null));
} else {
if(cljs.core.truth_((ok_pred.cljs$core$IFn$_invoke$arity$1 ? ok_pred.cljs$core$IFn$_invoke$arity$1(event) : ok_pred.call(null,event)))){
re_frame.core.remove_post_event_callback(cb_id);

cljs.core.reset_BANG_(new cljs.core.Keyword(null,"now-waiting-for","now-waiting-for",322402761).cljs$core$IFn$_invoke$arity$1(test_context),null);

var _STAR_test_context_STAR__orig_val__13470_13547 = day8.re_frame.test._STAR_test_context_STAR_;
var _STAR_test_context_STAR__temp_val__13471_13548 = test_context;
(day8.re_frame.test._STAR_test_context_STAR_ = _STAR_test_context_STAR__temp_val__13471_13548);

try{(callback.cljs$core$IFn$_invoke$arity$1 ? callback.cljs$core$IFn$_invoke$arity$1(event) : callback.call(null,event));
}finally {(day8.re_frame.test._STAR_test_context_STAR_ = _STAR_test_context_STAR__orig_val__13470_13547);
}
if(cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"wait-for-depth","wait-for-depth",-1366777331).cljs$core$IFn$_invoke$arity$1(test_context),cljs.core.deref(new cljs.core.Keyword(null,"max-wait-for-depth","max-wait-for-depth",639503457).cljs$core$IFn$_invoke$arity$1(test_context)))){
return (done.cljs$core$IFn$_invoke$arity$0 ? done.cljs$core$IFn$_invoke$arity$0() : done.call(null));
} else {
return null;
}
} else {
return null;

}
}
}));

return cljs.core.reset_BANG_(new cljs.core.Keyword(null,"now-waiting-for","now-waiting-for",322402761).cljs$core$IFn$_invoke$arity$1(test_context),ok_ids);
});
day8.re_frame.test._STAR_handling_STAR_ = false;
day8.re_frame.test.run_test_sync_STAR_ = (function day8$re_frame$test$run_test_sync_STAR_(f){
var restore_fn__13316__auto__ = re_frame.core.make_restore_fn();
try{var my_queue = cljs.core.atom.cljs$core$IFn$_invoke$arity$1(re_frame.interop.empty_queue);
var new_dispatch = (function (argv){
cljs.core.swap_BANG_.cljs$core$IFn$_invoke$arity$3(my_queue,cljs.core.conj,argv);

if(cljs.core.truth_(day8.re_frame.test._STAR_handling_STAR_)){
return null;
} else {
var _STAR_handling_STAR__orig_val__13485 = day8.re_frame.test._STAR_handling_STAR_;
var _STAR_handling_STAR__temp_val__13486 = true;
(day8.re_frame.test._STAR_handling_STAR_ = _STAR_handling_STAR__temp_val__13486);

try{while(true){
var temp__5823__auto__ = day8.re_frame.test.dequeue_BANG_(my_queue);
if(cljs.core.truth_(temp__5823__auto__)){
var queue_head = temp__5823__auto__;
re_frame.router.dispatch_sync(queue_head);

continue;
} else {
return null;
}
break;
}
}finally {(day8.re_frame.test._STAR_handling_STAR_ = _STAR_handling_STAR__orig_val__13485);
}}
});
var dispatch_orig_val__13492 = re_frame.core.dispatch;
var dispatch_orig_val__13493 = re_frame.router.dispatch;
var dispatch_temp_val__13494 = new_dispatch;
var dispatch_temp_val__13495 = new_dispatch;
(re_frame.core.dispatch = dispatch_temp_val__13494);

(re_frame.router.dispatch = dispatch_temp_val__13495);

try{return (f.cljs$core$IFn$_invoke$arity$0 ? f.cljs$core$IFn$_invoke$arity$0() : f.call(null));
}finally {(re_frame.router.dispatch = dispatch_orig_val__13493);

(re_frame.core.dispatch = dispatch_orig_val__13492);
}}finally {restore_fn__13316__auto__();
}});

//# sourceMappingURL=day8.re_frame.test.js.map
