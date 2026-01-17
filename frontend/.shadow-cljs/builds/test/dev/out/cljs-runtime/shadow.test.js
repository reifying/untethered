goog.provide('shadow.test');
/**
 * like ct/test-vars-block but more generic
 * groups vars by namespace, executes fixtures
 */
shadow.test.test_vars_grouped_block = (function shadow$test$test_vars_grouped_block(vars){
return cljs.core.mapcat.cljs$core$IFn$_invoke$arity$variadic((function (p__11576){
var vec__11579 = p__11576;
var ns = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11579,(0),null);
var vars__$1 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11579,(1),null);
return new cljs.core.PersistentVector(null, 3, 5, cljs.core.PersistentVector.EMPTY_NODE, [(function (){
return cljs.test.report.call(null,new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"type","type",1174270348),new cljs.core.Keyword(null,"begin-test-ns","begin-test-ns",-1701237033),new cljs.core.Keyword(null,"ns","ns",441598760),ns], null));
}),(function (){
return cljs.test.block((function (){var env = cljs.test.get_current_env();
var once_fixtures = cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(env,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"once-fixtures","once-fixtures",1253947167),ns], null));
var each_fixtures = cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(env,new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"each-fixtures","each-fixtures",802243977),ns], null));
var G__11587 = cljs.test.execution_strategy(once_fixtures,each_fixtures);
var G__11587__$1 = (((G__11587 instanceof cljs.core.Keyword))?G__11587.fqn:null);
switch (G__11587__$1) {
case "async":
return cljs.test.wrap_map_fixtures(once_fixtures,cljs.core.mapcat.cljs$core$IFn$_invoke$arity$variadic(cljs.core.comp.cljs$core$IFn$_invoke$arity$2(cljs.core.partial.cljs$core$IFn$_invoke$arity$2(cljs.test.wrap_map_fixtures,each_fixtures),cljs.test.test_var_block),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([cljs.core.filter.cljs$core$IFn$_invoke$arity$2(cljs.core.comp.cljs$core$IFn$_invoke$arity$2(new cljs.core.Keyword(null,"test","test",577538877),cljs.core.meta),vars__$1)], 0)));

break;
case "sync":
var each_fixture_fn = cljs.test.join_fixtures(each_fixtures);
return new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [(function (){
var G__11596 = (function (){
var seq__11601 = cljs.core.seq(vars__$1);
var chunk__11602 = null;
var count__11603 = (0);
var i__11604 = (0);
while(true){
if((i__11604 < count__11603)){
var v = chunk__11602.cljs$core$IIndexed$_nth$arity$2(null,i__11604);
var temp__5823__auto___11774 = new cljs.core.Keyword(null,"test","test",577538877).cljs$core$IFn$_invoke$arity$1(cljs.core.meta(v));
if(cljs.core.truth_(temp__5823__auto___11774)){
var t_11777 = temp__5823__auto___11774;
var G__11622_11778 = ((function (seq__11601,chunk__11602,count__11603,i__11604,t_11777,temp__5823__auto___11774,v,each_fixture_fn,G__11587,G__11587__$1,env,once_fixtures,each_fixtures,vec__11579,ns,vars__$1){
return (function (){
return cljs.test.run_block(cljs.test.test_var_block_STAR_(v,cljs.test.disable_async(t_11777)));
});})(seq__11601,chunk__11602,count__11603,i__11604,t_11777,temp__5823__auto___11774,v,each_fixture_fn,G__11587,G__11587__$1,env,once_fixtures,each_fixtures,vec__11579,ns,vars__$1))
;
(each_fixture_fn.cljs$core$IFn$_invoke$arity$1 ? each_fixture_fn.cljs$core$IFn$_invoke$arity$1(G__11622_11778) : each_fixture_fn.call(null,G__11622_11778));
} else {
}


var G__11787 = seq__11601;
var G__11788 = chunk__11602;
var G__11789 = count__11603;
var G__11790 = (i__11604 + (1));
seq__11601 = G__11787;
chunk__11602 = G__11788;
count__11603 = G__11789;
i__11604 = G__11790;
continue;
} else {
var temp__5823__auto__ = cljs.core.seq(seq__11601);
if(temp__5823__auto__){
var seq__11601__$1 = temp__5823__auto__;
if(cljs.core.chunked_seq_QMARK_(seq__11601__$1)){
var c__5673__auto__ = cljs.core.chunk_first(seq__11601__$1);
var G__11791 = cljs.core.chunk_rest(seq__11601__$1);
var G__11792 = c__5673__auto__;
var G__11793 = cljs.core.count(c__5673__auto__);
var G__11794 = (0);
seq__11601 = G__11791;
chunk__11602 = G__11792;
count__11603 = G__11793;
i__11604 = G__11794;
continue;
} else {
var v = cljs.core.first(seq__11601__$1);
var temp__5823__auto___11799__$1 = new cljs.core.Keyword(null,"test","test",577538877).cljs$core$IFn$_invoke$arity$1(cljs.core.meta(v));
if(cljs.core.truth_(temp__5823__auto___11799__$1)){
var t_11801 = temp__5823__auto___11799__$1;
var G__11625_11802 = ((function (seq__11601,chunk__11602,count__11603,i__11604,t_11801,temp__5823__auto___11799__$1,v,seq__11601__$1,temp__5823__auto__,each_fixture_fn,G__11587,G__11587__$1,env,once_fixtures,each_fixtures,vec__11579,ns,vars__$1){
return (function (){
return cljs.test.run_block(cljs.test.test_var_block_STAR_(v,cljs.test.disable_async(t_11801)));
});})(seq__11601,chunk__11602,count__11603,i__11604,t_11801,temp__5823__auto___11799__$1,v,seq__11601__$1,temp__5823__auto__,each_fixture_fn,G__11587,G__11587__$1,env,once_fixtures,each_fixtures,vec__11579,ns,vars__$1))
;
(each_fixture_fn.cljs$core$IFn$_invoke$arity$1 ? each_fixture_fn.cljs$core$IFn$_invoke$arity$1(G__11625_11802) : each_fixture_fn.call(null,G__11625_11802));
} else {
}


var G__11805 = cljs.core.next(seq__11601__$1);
var G__11806 = null;
var G__11807 = (0);
var G__11808 = (0);
seq__11601 = G__11805;
chunk__11602 = G__11806;
count__11603 = G__11807;
i__11604 = G__11808;
continue;
}
} else {
return null;
}
}
break;
}
});
var fexpr__11595 = cljs.test.join_fixtures(once_fixtures);
return (fexpr__11595.cljs$core$IFn$_invoke$arity$1 ? fexpr__11595.cljs$core$IFn$_invoke$arity$1(G__11596) : fexpr__11595.call(null,G__11596));
})], null);

break;
default:
throw (new Error((""+"No matching clause: "+cljs.core.str.cljs$core$IFn$_invoke$arity$1(G__11587__$1))));

}
})());
}),(function (){
return cljs.test.report.call(null,new cljs.core.PersistentArrayMap(null, 2, [new cljs.core.Keyword(null,"type","type",1174270348),new cljs.core.Keyword(null,"end-test-ns","end-test-ns",1620675645),new cljs.core.Keyword(null,"ns","ns",441598760),ns], null));
})], null);
}),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([cljs.core.sort_by.cljs$core$IFn$_invoke$arity$2(cljs.core.first,cljs.core.group_by((function (p1__11567_SHARP_){
return new cljs.core.Keyword(null,"ns","ns",441598760).cljs$core$IFn$_invoke$arity$1(cljs.core.meta(p1__11567_SHARP_));
}),vars))], 0));
});
/**
 * Like test-ns, but returns a block for further composition and
 *   later execution.  Does not clear the current env.
 */
shadow.test.test_ns_block = (function shadow$test$test_ns_block(ns){
if((ns instanceof cljs.core.Symbol)){
} else {
throw (new Error("Assert failed: (symbol? ns)"));
}

var map__11650 = shadow.test.env.get_test_ns_info(ns);
var map__11650__$1 = cljs.core.__destructure_map(map__11650);
var test_ns = map__11650__$1;
var vars = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11650__$1,new cljs.core.Keyword(null,"vars","vars",-2046957217));
if(cljs.core.not(test_ns)){
return new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [(function (){
return cljs.core.println.cljs$core$IFn$_invoke$arity$variadic(cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([(""+"Namespace: "+cljs.core.str.cljs$core$IFn$_invoke$arity$1(ns)+" not found, no tests to run.")], 0));
})], null);
} else {
return shadow.test.test_vars_grouped_block(vars);
}
});
shadow.test.prepare_test_run = (function shadow$test$prepare_test_run(p__11661,vars){
var map__11662 = p__11661;
var map__11662__$1 = cljs.core.__destructure_map(map__11662);
var env = map__11662__$1;
var report_fn = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11662__$1,new cljs.core.Keyword(null,"report-fn","report-fn",-549046115));
var orig_report = cljs.test.report;
return new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [(function (){
cljs.test.set_env_BANG_(cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(env,new cljs.core.Keyword("shadow.test","report-fn","shadow.test/report-fn",1075704061),orig_report));

if(cljs.core.truth_(report_fn)){
(cljs.test.report = report_fn);
} else {
}

var seq__11665_11813 = cljs.core.seq(shadow.test.env.get_tests());
var chunk__11667_11814 = null;
var count__11668_11815 = (0);
var i__11669_11816 = (0);
while(true){
if((i__11669_11816 < count__11668_11815)){
var vec__11699_11817 = chunk__11667_11814.cljs$core$IIndexed$_nth$arity$2(null,i__11669_11816);
var test_ns_11818 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11699_11817,(0),null);
var ns_info_11819 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11699_11817,(1),null);
var map__11704_11820 = ns_info_11819;
var map__11704_11821__$1 = cljs.core.__destructure_map(map__11704_11820);
var fixtures_11822 = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11704_11821__$1,new cljs.core.Keyword(null,"fixtures","fixtures",1009814994));
var temp__5823__auto___11823 = new cljs.core.Keyword(null,"once","once",-262568523).cljs$core$IFn$_invoke$arity$1(fixtures_11822);
if(cljs.core.truth_(temp__5823__auto___11823)){
var fix_11825 = temp__5823__auto___11823;
cljs.test.update_current_env_BANG_.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"once-fixtures","once-fixtures",1253947167)], null),cljs.core.assoc,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([test_ns_11818,fix_11825], 0));
} else {
}

var temp__5823__auto___11826 = new cljs.core.Keyword(null,"each","each",940016129).cljs$core$IFn$_invoke$arity$1(fixtures_11822);
if(cljs.core.truth_(temp__5823__auto___11826)){
var fix_11827 = temp__5823__auto___11826;
cljs.test.update_current_env_BANG_.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"each-fixtures","each-fixtures",802243977)], null),cljs.core.assoc,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([test_ns_11818,fix_11827], 0));
} else {
}


var G__11830 = seq__11665_11813;
var G__11831 = chunk__11667_11814;
var G__11832 = count__11668_11815;
var G__11833 = (i__11669_11816 + (1));
seq__11665_11813 = G__11830;
chunk__11667_11814 = G__11831;
count__11668_11815 = G__11832;
i__11669_11816 = G__11833;
continue;
} else {
var temp__5823__auto___11834 = cljs.core.seq(seq__11665_11813);
if(temp__5823__auto___11834){
var seq__11665_11835__$1 = temp__5823__auto___11834;
if(cljs.core.chunked_seq_QMARK_(seq__11665_11835__$1)){
var c__5673__auto___11836 = cljs.core.chunk_first(seq__11665_11835__$1);
var G__11837 = cljs.core.chunk_rest(seq__11665_11835__$1);
var G__11838 = c__5673__auto___11836;
var G__11839 = cljs.core.count(c__5673__auto___11836);
var G__11840 = (0);
seq__11665_11813 = G__11837;
chunk__11667_11814 = G__11838;
count__11668_11815 = G__11839;
i__11669_11816 = G__11840;
continue;
} else {
var vec__11715_11841 = cljs.core.first(seq__11665_11835__$1);
var test_ns_11842 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11715_11841,(0),null);
var ns_info_11843 = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11715_11841,(1),null);
var map__11720_11845 = ns_info_11843;
var map__11720_11846__$1 = cljs.core.__destructure_map(map__11720_11845);
var fixtures_11847 = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11720_11846__$1,new cljs.core.Keyword(null,"fixtures","fixtures",1009814994));
var temp__5823__auto___11848__$1 = new cljs.core.Keyword(null,"once","once",-262568523).cljs$core$IFn$_invoke$arity$1(fixtures_11847);
if(cljs.core.truth_(temp__5823__auto___11848__$1)){
var fix_11849 = temp__5823__auto___11848__$1;
cljs.test.update_current_env_BANG_.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"once-fixtures","once-fixtures",1253947167)], null),cljs.core.assoc,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([test_ns_11842,fix_11849], 0));
} else {
}

var temp__5823__auto___11851__$1 = new cljs.core.Keyword(null,"each","each",940016129).cljs$core$IFn$_invoke$arity$1(fixtures_11847);
if(cljs.core.truth_(temp__5823__auto___11851__$1)){
var fix_11852 = temp__5823__auto___11851__$1;
cljs.test.update_current_env_BANG_.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [new cljs.core.Keyword(null,"each-fixtures","each-fixtures",802243977)], null),cljs.core.assoc,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([test_ns_11842,fix_11852], 0));
} else {
}


var G__11853 = cljs.core.next(seq__11665_11835__$1);
var G__11854 = null;
var G__11855 = (0);
var G__11856 = (0);
seq__11665_11813 = G__11853;
chunk__11667_11814 = G__11854;
count__11668_11815 = G__11855;
i__11669_11816 = G__11856;
continue;
}
} else {
}
}
break;
}

return cljs.test.report.call(null,new cljs.core.PersistentArrayMap(null, 3, [new cljs.core.Keyword(null,"type","type",1174270348),new cljs.core.Keyword(null,"begin-run-tests","begin-run-tests",309363062),new cljs.core.Keyword(null,"var-count","var-count",-1513152110),cljs.core.count(vars),new cljs.core.Keyword(null,"ns-count","ns-count",-1269070724),cljs.core.count(cljs.core.set(cljs.core.map.cljs$core$IFn$_invoke$arity$2((function (p1__11651_SHARP_){
return new cljs.core.Keyword(null,"ns","ns",441598760).cljs$core$IFn$_invoke$arity$1(cljs.core.meta(p1__11651_SHARP_));
}),vars)))], null));
})], null);
});
shadow.test.finish_test_run = (function shadow$test$finish_test_run(block){
if(cljs.core.vector_QMARK_(block)){
} else {
throw (new Error("Assert failed: (vector? block)"));
}

return cljs.core.conj.cljs$core$IFn$_invoke$arity$2(block,(function (){
var map__11729 = cljs.test.get_current_env();
var map__11729__$1 = cljs.core.__destructure_map(map__11729);
var env = map__11729__$1;
var report_fn = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11729__$1,new cljs.core.Keyword("shadow.test","report-fn","shadow.test/report-fn",1075704061));
var report_counters = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11729__$1,new cljs.core.Keyword(null,"report-counters","report-counters",-1702609242));
cljs.test.report.call(null,cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(report_counters,new cljs.core.Keyword(null,"type","type",1174270348),new cljs.core.Keyword(null,"summary","summary",380847952)));

cljs.test.report.call(null,cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(report_counters,new cljs.core.Keyword(null,"type","type",1174270348),new cljs.core.Keyword(null,"end-run-tests","end-run-tests",267300563)));

return (cljs.test.report = report_fn);
}));
});
/**
 * tests all vars grouped by namespace, expects seq of test vars, can be obtained from env
 */
shadow.test.run_test_vars = (function shadow$test$run_test_vars(var_args){
var G__11734 = arguments.length;
switch (G__11734) {
case 1:
return shadow.test.run_test_vars.cljs$core$IFn$_invoke$arity$1((arguments[(0)]));

break;
case 2:
return shadow.test.run_test_vars.cljs$core$IFn$_invoke$arity$2((arguments[(0)]),(arguments[(1)]));

break;
default:
throw (new Error(["Invalid arity: ",arguments.length].join("")));

}
});

(shadow.test.run_test_vars.cljs$core$IFn$_invoke$arity$1 = (function (test_vars){
return shadow.test.run_test_vars.cljs$core$IFn$_invoke$arity$2(cljs.test.empty_env.cljs$core$IFn$_invoke$arity$0(),test_vars);
}));

(shadow.test.run_test_vars.cljs$core$IFn$_invoke$arity$2 = (function (env,vars){
return cljs.test.run_block(shadow.test.finish_test_run(cljs.core.into.cljs$core$IFn$_invoke$arity$2(shadow.test.prepare_test_run(env,vars),shadow.test.test_vars_grouped_block(vars))));
}));

(shadow.test.run_test_vars.cljs$lang$maxFixedArity = 2);

/**
 * test all vars for given namespace symbol
 */
shadow.test.test_ns = (function shadow$test$test_ns(var_args){
var G__11742 = arguments.length;
switch (G__11742) {
case 1:
return shadow.test.test_ns.cljs$core$IFn$_invoke$arity$1((arguments[(0)]));

break;
case 2:
return shadow.test.test_ns.cljs$core$IFn$_invoke$arity$2((arguments[(0)]),(arguments[(1)]));

break;
default:
throw (new Error(["Invalid arity: ",arguments.length].join("")));

}
});

(shadow.test.test_ns.cljs$core$IFn$_invoke$arity$1 = (function (ns){
return shadow.test.test_ns.cljs$core$IFn$_invoke$arity$2(cljs.test.empty_env.cljs$core$IFn$_invoke$arity$0(),ns);
}));

(shadow.test.test_ns.cljs$core$IFn$_invoke$arity$2 = (function (env,ns){
var map__11744 = shadow.test.env.get_test_ns_info(ns);
var map__11744__$1 = cljs.core.__destructure_map(map__11744);
var vars = cljs.core.get.cljs$core$IFn$_invoke$arity$2(map__11744__$1,new cljs.core.Keyword(null,"vars","vars",-2046957217));
return cljs.test.run_block(shadow.test.finish_test_run(cljs.core.into.cljs$core$IFn$_invoke$arity$2(shadow.test.prepare_test_run(env,vars),shadow.test.test_vars_grouped_block(vars))));
}));

(shadow.test.test_ns.cljs$lang$maxFixedArity = 2);

/**
 * test all vars in specified namespace symbol set
 */
shadow.test.run_tests = (function shadow$test$run_tests(var_args){
var G__11747 = arguments.length;
switch (G__11747) {
case 0:
return shadow.test.run_tests.cljs$core$IFn$_invoke$arity$0();

break;
case 1:
return shadow.test.run_tests.cljs$core$IFn$_invoke$arity$1((arguments[(0)]));

break;
case 2:
return shadow.test.run_tests.cljs$core$IFn$_invoke$arity$2((arguments[(0)]),(arguments[(1)]));

break;
default:
throw (new Error(["Invalid arity: ",arguments.length].join("")));

}
});

(shadow.test.run_tests.cljs$core$IFn$_invoke$arity$0 = (function (){
return shadow.test.run_tests.cljs$core$IFn$_invoke$arity$1(cljs.test.empty_env.cljs$core$IFn$_invoke$arity$0());
}));

(shadow.test.run_tests.cljs$core$IFn$_invoke$arity$1 = (function (env){
return shadow.test.run_tests.cljs$core$IFn$_invoke$arity$2(env,shadow.test.env.get_test_namespaces());
}));

(shadow.test.run_tests.cljs$core$IFn$_invoke$arity$2 = (function (env,namespaces){
if(cljs.core.set_QMARK_(namespaces)){
} else {
throw (new Error("Assert failed: (set? namespaces)"));
}

var vars = cljs.core.filter.cljs$core$IFn$_invoke$arity$2((function (p1__11745_SHARP_){
return cljs.core.contains_QMARK_(namespaces,new cljs.core.Keyword(null,"ns","ns",441598760).cljs$core$IFn$_invoke$arity$1(cljs.core.meta(p1__11745_SHARP_)));
}),shadow.test.env.get_test_vars());
return cljs.test.run_block(shadow.test.finish_test_run(cljs.core.into.cljs$core$IFn$_invoke$arity$2(shadow.test.prepare_test_run(env,vars),shadow.test.test_vars_grouped_block(vars))));
}));

(shadow.test.run_tests.cljs$lang$maxFixedArity = 2);

/**
 * Runs all tests in all namespaces; prints results.
 *   Optional argument is a regular expression; only namespaces with
 *   names matching the regular expression (with re-matches) will be
 *   tested.
 */
shadow.test.run_all_tests = (function shadow$test$run_all_tests(var_args){
var G__11762 = arguments.length;
switch (G__11762) {
case 0:
return shadow.test.run_all_tests.cljs$core$IFn$_invoke$arity$0();

break;
case 1:
return shadow.test.run_all_tests.cljs$core$IFn$_invoke$arity$1((arguments[(0)]));

break;
case 2:
return shadow.test.run_all_tests.cljs$core$IFn$_invoke$arity$2((arguments[(0)]),(arguments[(1)]));

break;
default:
throw (new Error(["Invalid arity: ",arguments.length].join("")));

}
});

(shadow.test.run_all_tests.cljs$core$IFn$_invoke$arity$0 = (function (){
return shadow.test.run_all_tests.cljs$core$IFn$_invoke$arity$2(cljs.test.empty_env.cljs$core$IFn$_invoke$arity$0(),null);
}));

(shadow.test.run_all_tests.cljs$core$IFn$_invoke$arity$1 = (function (env){
return shadow.test.run_all_tests.cljs$core$IFn$_invoke$arity$2(env,null);
}));

(shadow.test.run_all_tests.cljs$core$IFn$_invoke$arity$2 = (function (env,re){
return shadow.test.run_tests.cljs$core$IFn$_invoke$arity$2(env,cljs.core.into.cljs$core$IFn$_invoke$arity$2(cljs.core.PersistentHashSet.EMPTY,cljs.core.filter.cljs$core$IFn$_invoke$arity$2((function (p1__11758_SHARP_){
var or__5142__auto__ = (re == null);
if(or__5142__auto__){
return or__5142__auto__;
} else {
return cljs.core.re_matches(re,(""+cljs.core.str.cljs$core$IFn$_invoke$arity$1(p1__11758_SHARP_)));
}
}),shadow.test.env.get_test_namespaces())));
}));

(shadow.test.run_all_tests.cljs$lang$maxFixedArity = 2);


//# sourceMappingURL=shadow.test.js.map
