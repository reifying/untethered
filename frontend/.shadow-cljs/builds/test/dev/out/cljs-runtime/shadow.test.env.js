goog.provide('shadow.test.env');
/**
 * @define {boolean}
 * @type {boolean}
 */
shadow.test.env.UI_DRIVEN = goog.define("shadow.test.env.UI_DRIVEN",false);
if((typeof shadow !== 'undefined') && (typeof shadow.test !== 'undefined') && (typeof shadow.test.env !== 'undefined') && (typeof shadow.test.env.tests_ref !== 'undefined')){
} else {
shadow.test.env.tests_ref = cljs.core.atom.cljs$core$IFn$_invoke$arity$1(new cljs.core.PersistentArrayMap(null, 1, [new cljs.core.Keyword(null,"namespaces","namespaces",-1444157469),cljs.core.PersistentArrayMap.EMPTY], null));
}
shadow.test.env.reset_test_data_BANG_ = (function shadow$test$env$reset_test_data_BANG_(test_data){
return cljs.core.swap_BANG_.cljs$core$IFn$_invoke$arity$4(shadow.test.env.tests_ref,cljs.core.assoc,new cljs.core.Keyword(null,"namespaces","namespaces",-1444157469),test_data);
});
shadow.test.env.get_tests = (function shadow$test$env$get_tests(){
return cljs.core.get.cljs$core$IFn$_invoke$arity$2(cljs.core.deref(shadow.test.env.tests_ref),new cljs.core.Keyword(null,"namespaces","namespaces",-1444157469));
});
shadow.test.env.get_test_vars = (function shadow$test$env$get_test_vars(){
var iter__5628__auto__ = (function shadow$test$env$get_test_vars_$_iter__7412(s__7413){
return (new cljs.core.LazySeq(null,(function (){
var s__7413__$1 = s__7413;
while(true){
var temp__5823__auto__ = cljs.core.seq(s__7413__$1);
if(temp__5823__auto__){
var xs__6383__auto__ = temp__5823__auto__;
var vec__7422 = cljs.core.first(xs__6383__auto__);
var ns = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__7422,(0),null);
var ns_info = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__7422,(1),null);
var iterys__5624__auto__ = ((function (s__7413__$1,vec__7422,ns,ns_info,xs__6383__auto__,temp__5823__auto__){
return (function shadow$test$env$get_test_vars_$_iter__7412_$_iter__7414(s__7415){
return (new cljs.core.LazySeq(null,((function (s__7413__$1,vec__7422,ns,ns_info,xs__6383__auto__,temp__5823__auto__){
return (function (){
var s__7415__$1 = s__7415;
while(true){
var temp__5823__auto____$1 = cljs.core.seq(s__7415__$1);
if(temp__5823__auto____$1){
var s__7415__$2 = temp__5823__auto____$1;
if(cljs.core.chunked_seq_QMARK_(s__7415__$2)){
var c__5626__auto__ = cljs.core.chunk_first(s__7415__$2);
var size__5627__auto__ = cljs.core.count(c__5626__auto__);
var b__7417 = cljs.core.chunk_buffer(size__5627__auto__);
if((function (){var i__7416 = (0);
while(true){
if((i__7416 < size__5627__auto__)){
var var$ = cljs.core._nth(c__5626__auto__,i__7416);
cljs.core.chunk_append(b__7417,var$);

var G__7474 = (i__7416 + (1));
i__7416 = G__7474;
continue;
} else {
return true;
}
break;
}
})()){
return cljs.core.chunk_cons(cljs.core.chunk(b__7417),shadow$test$env$get_test_vars_$_iter__7412_$_iter__7414(cljs.core.chunk_rest(s__7415__$2)));
} else {
return cljs.core.chunk_cons(cljs.core.chunk(b__7417),null);
}
} else {
var var$ = cljs.core.first(s__7415__$2);
return cljs.core.cons(var$,shadow$test$env$get_test_vars_$_iter__7412_$_iter__7414(cljs.core.rest(s__7415__$2)));
}
} else {
return null;
}
break;
}
});})(s__7413__$1,vec__7422,ns,ns_info,xs__6383__auto__,temp__5823__auto__))
,null,null));
});})(s__7413__$1,vec__7422,ns,ns_info,xs__6383__auto__,temp__5823__auto__))
;
var fs__5625__auto__ = cljs.core.seq(iterys__5624__auto__(new cljs.core.Keyword(null,"vars","vars",-2046957217).cljs$core$IFn$_invoke$arity$1(ns_info)));
if(fs__5625__auto__){
return cljs.core.concat.cljs$core$IFn$_invoke$arity$2(fs__5625__auto__,shadow$test$env$get_test_vars_$_iter__7412(cljs.core.rest(s__7413__$1)));
} else {
var G__7481 = cljs.core.rest(s__7413__$1);
s__7413__$1 = G__7481;
continue;
}
} else {
return null;
}
break;
}
}),null,null));
});
return iter__5628__auto__(shadow.test.env.get_tests());
});
shadow.test.env.get_test_ns_info = (function shadow$test$env$get_test_ns_info(ns){
if((ns instanceof cljs.core.Symbol)){
} else {
throw (new Error("Assert failed: (symbol? ns)"));
}

return cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(cljs.core.deref(shadow.test.env.tests_ref),new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"namespaces","namespaces",-1444157469),ns], null));
});
/**
 * returns all the registered test namespaces and symbols
 * use (get-test-ns-info the-sym) to get the details
 */
shadow.test.env.get_test_namespaces = (function shadow$test$env$get_test_namespaces(){
return cljs.core.keys(new cljs.core.Keyword(null,"namespaces","namespaces",-1444157469).cljs$core$IFn$_invoke$arity$1(cljs.core.deref(shadow.test.env.tests_ref)));
});
shadow.test.env.get_test_count = (function shadow$test$env$get_test_count(){
return cljs.core.reduce.cljs$core$IFn$_invoke$arity$3(cljs.core._PLUS_,(0),(function (){var iter__5628__auto__ = (function shadow$test$env$get_test_count_$_iter__7440(s__7441){
return (new cljs.core.LazySeq(null,(function (){
var s__7441__$1 = s__7441;
while(true){
var temp__5823__auto__ = cljs.core.seq(s__7441__$1);
if(temp__5823__auto__){
var s__7441__$2 = temp__5823__auto__;
if(cljs.core.chunked_seq_QMARK_(s__7441__$2)){
var c__5626__auto__ = cljs.core.chunk_first(s__7441__$2);
var size__5627__auto__ = cljs.core.count(c__5626__auto__);
var b__7443 = cljs.core.chunk_buffer(size__5627__auto__);
if((function (){var i__7442 = (0);
while(true){
if((i__7442 < size__5627__auto__)){
var map__7444 = cljs.core._nth(c__5626__auto__,i__7442);
var map__7444__$1 = cljs.core.__destructure_map(map__7444);
var test_ns = map__7444__$1;
var vars = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__7444__$1,new cljs.core.Keyword(null,"vars","vars",-2046957217));
cljs.core.chunk_append(b__7443,cljs.core.count(vars));

var G__7493 = (i__7442 + (1));
i__7442 = G__7493;
continue;
} else {
return true;
}
break;
}
})()){
return cljs.core.chunk_cons(cljs.core.chunk(b__7443),shadow$test$env$get_test_count_$_iter__7440(cljs.core.chunk_rest(s__7441__$2)));
} else {
return cljs.core.chunk_cons(cljs.core.chunk(b__7443),null);
}
} else {
var map__7446 = cljs.core.first(s__7441__$2);
var map__7446__$1 = cljs.core.__destructure_map(map__7446);
var test_ns = map__7446__$1;
var vars = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__7446__$1,new cljs.core.Keyword(null,"vars","vars",-2046957217));
return cljs.core.cons(cljs.core.count(vars),shadow$test$env$get_test_count_$_iter__7440(cljs.core.rest(s__7441__$2)));
}
} else {
return null;
}
break;
}
}),null,null));
});
return iter__5628__auto__(cljs.core.vals(new cljs.core.Keyword(null,"namespaces","namespaces",-1444157469).cljs$core$IFn$_invoke$arity$1(cljs.core.deref(shadow.test.env.tests_ref))));
})());
});

//# sourceMappingURL=shadow.test.env.js.map
