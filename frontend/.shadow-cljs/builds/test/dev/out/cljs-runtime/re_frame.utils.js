goog.provide('re_frame.utils');
/**
 * Dissociates an entry from a nested associative structure returning a new
 *   nested structure. keys is a sequence of keys. Any empty maps that result
 *   will not be present in the new structure.
 *   The key thing is that 'm' remains identical? to itself if the path was never present
 */
re_frame.utils.dissoc_in = (function re_frame$utils$dissoc_in(m,p__9070){
var vec__9071 = p__9070;
var seq__9072 = cljs.core.seq(vec__9071);
var first__9073 = cljs.core.first(seq__9072);
var seq__9072__$1 = cljs.core.next(seq__9072);
var k = first__9073;
var ks = seq__9072__$1;
var keys = vec__9071;
if(ks){
var temp__5821__auto__ = cljs.core.get.cljs$core$IFn$_invoke$arity$2(m,k);
if(cljs.core.truth_(temp__5821__auto__)){
var nextmap = temp__5821__auto__;
var newmap = (re_frame.utils.dissoc_in.cljs$core$IFn$_invoke$arity$2 ? re_frame.utils.dissoc_in.cljs$core$IFn$_invoke$arity$2(nextmap,ks) : re_frame.utils.dissoc_in.call(null,nextmap,ks));
if(cljs.core.seq(newmap)){
return cljs.core.assoc.cljs$core$IFn$_invoke$arity$3(m,k,newmap);
} else {
return cljs.core.dissoc.cljs$core$IFn$_invoke$arity$2(m,k);
}
} else {
return m;
}
} else {
return cljs.core.dissoc.cljs$core$IFn$_invoke$arity$2(m,k);
}
});
re_frame.utils.first_in_vector = (function re_frame$utils$first_in_vector(v){
if(cljs.core.vector_QMARK_(v)){
return cljs.core.first(v);
} else {
return re_frame.loggers.console.cljs$core$IFn$_invoke$arity$variadic(new cljs.core.Keyword(null,"error","error",-978969032),cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2(["re-frame: expected a vector, but got:",v], 0));
}
});
/**
 * Like apply, but f takes keyword arguments and the last argument is
 *   not a seq but a map with the arguments for f
 */
re_frame.utils.apply_kw = (function re_frame$utils$apply_kw(var_args){
var args__5882__auto__ = [];
var len__5876__auto___9182 = arguments.length;
var i__5877__auto___9183 = (0);
while(true){
if((i__5877__auto___9183 < len__5876__auto___9182)){
args__5882__auto__.push((arguments[i__5877__auto___9183]));

var G__9184 = (i__5877__auto___9183 + (1));
i__5877__auto___9183 = G__9184;
continue;
} else {
}
break;
}

var argseq__5883__auto__ = ((((1) < args__5882__auto__.length))?(new cljs.core.IndexedSeq(args__5882__auto__.slice((1)),(0),null)):null);
return re_frame.utils.apply_kw.cljs$core$IFn$_invoke$arity$variadic((arguments[(0)]),argseq__5883__auto__);
});

(re_frame.utils.apply_kw.cljs$core$IFn$_invoke$arity$variadic = (function (f,args){
if(cljs.core.map_QMARK_(cljs.core.last(args))){
} else {
throw (new Error("Assert failed: (map? (last args))"));
}

return cljs.core.apply.cljs$core$IFn$_invoke$arity$2(f,cljs.core.apply.cljs$core$IFn$_invoke$arity$3(cljs.core.concat,cljs.core.butlast(args),cljs.core.last(args)));
}));

(re_frame.utils.apply_kw.cljs$lang$maxFixedArity = (1));

/** @this {Function} */
(re_frame.utils.apply_kw.cljs$lang$applyTo = (function (seq9081){
var G__9082 = cljs.core.first(seq9081);
var seq9081__$1 = cljs.core.next(seq9081);
var self__5861__auto__ = this;
return self__5861__auto__.cljs$core$IFn$_invoke$arity$variadic(G__9082,seq9081__$1);
}));

re_frame.utils.map_vals = (function re_frame$utils$map_vals(f,m){
return cljs.core.into.cljs$core$IFn$_invoke$arity$3(cljs.core.PersistentArrayMap.EMPTY,cljs.core.map.cljs$core$IFn$_invoke$arity$1((function (p__9097){
var vec__9098 = p__9097;
var k = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__9098,(0),null);
var v = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__9098,(1),null);
return new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [k,(f.cljs$core$IFn$_invoke$arity$1 ? f.cljs$core$IFn$_invoke$arity$1(v) : f.call(null,v))], null);
})),m);
});
re_frame.utils.find_cycle = (function re_frame$utils$find_cycle(graph,visited,node){
var stack = new cljs.core.PersistentVector(null, 1, 5, cljs.core.PersistentVector.EMPTY_NODE, [node], null);
var path = cljs.core.PersistentVector.EMPTY;
while(true){
var current = cljs.core.peek(stack);
if(cljs.core.truth_(cljs.core.some(cljs.core.PersistentHashSet.createAsIfByAssoc([current]),path))){
return cljs.core.conj.cljs$core$IFn$_invoke$arity$2(cljs.core.take_while.cljs$core$IFn$_invoke$arity$2(((function (stack,path,current){
return (function (p1__9109_SHARP_){
return cljs.core.not_EQ_.cljs$core$IFn$_invoke$arity$2(p1__9109_SHARP_,current);
});})(stack,path,current))
,cljs.core.reverse(path)),current);
} else {
var temp__5821__auto__ = cljs.core.seq(cljs.core.get.cljs$core$IFn$_invoke$arity$2(graph,current));
if(temp__5821__auto__){
var neighbors = temp__5821__auto__;
var G__9193 = cljs.core.into.cljs$core$IFn$_invoke$arity$2(stack,cljs.core.disj.cljs$core$IFn$_invoke$arity$2(cljs.core.set(neighbors),visited));
var G__9194 = cljs.core.conj.cljs$core$IFn$_invoke$arity$2(path,current);
stack = G__9193;
path = G__9194;
continue;
} else {
var G__9195 = cljs.core.pop(stack);
var G__9196 = path;
stack = G__9195;
path = G__9196;
continue;
}
}
break;
}
});
re_frame.utils.topsort_kahn = (function re_frame$utils$topsort_kahn(graph){
var in_degree = cljs.core.reduce.cljs$core$IFn$_invoke$arity$3((function (acc,p__9137){
var vec__9138 = p__9137;
var node = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__9138,(0),null);
var neighbors = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__9138,(1),null);
return cljs.core.reduce.cljs$core$IFn$_invoke$arity$3((function (a,neighbor){
return cljs.core.update.cljs$core$IFn$_invoke$arity$3(a,neighbor,cljs.core.inc);
}),acc,neighbors);
}),cljs.core.PersistentArrayMap.EMPTY,graph);
var ks = cljs.core.keys(graph);
var q = cljs.core.filter.cljs$core$IFn$_invoke$arity$2(((function (in_degree,ks){
return (function (p1__9134_SHARP_){
return (cljs.core.get.cljs$core$IFn$_invoke$arity$3(in_degree,p1__9134_SHARP_,(0)) === (0));
});})(in_degree,ks))
,ks);
var sorted = re_frame.interop.empty_queue;
var in_degree__$1 = in_degree;
while(true){
if(cljs.core.seq(q)){
var current = cljs.core.first(q);
var neighbors = cljs.core.get.cljs$core$IFn$_invoke$arity$3(graph,current,cljs.core.PersistentVector.EMPTY);
var updated_in_degree = cljs.core.reduce.cljs$core$IFn$_invoke$arity$3(((function (q,sorted,in_degree__$1,current,neighbors,in_degree,ks){
return (function (acc,neighbor){
return cljs.core.update.cljs$core$IFn$_invoke$arity$3(acc,neighbor,cljs.core.dec);
});})(q,sorted,in_degree__$1,current,neighbors,in_degree,ks))
,in_degree__$1,neighbors);
var new_q = cljs.core.concat.cljs$core$IFn$_invoke$arity$2(cljs.core.rest(q),cljs.core.filter.cljs$core$IFn$_invoke$arity$2(((function (q,sorted,in_degree__$1,current,neighbors,updated_in_degree,in_degree,ks){
return (function (p1__9135_SHARP_){
return cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2((0),cljs.core.get.cljs$core$IFn$_invoke$arity$2(updated_in_degree,p1__9135_SHARP_));
});})(q,sorted,in_degree__$1,current,neighbors,updated_in_degree,in_degree,ks))
,neighbors));
var G__9202 = new_q;
var G__9203 = cljs.core.conj.cljs$core$IFn$_invoke$arity$2(sorted,current);
var G__9204 = updated_in_degree;
q = G__9202;
sorted = G__9203;
in_degree__$1 = G__9204;
continue;
} else {
if(cljs.core._EQ_.cljs$core$IFn$_invoke$arity$2(cljs.core.count(sorted),cljs.core.count(ks))){
return sorted;
} else {
var unvisited = cljs.core.remove.cljs$core$IFn$_invoke$arity$2(cljs.core.set(sorted),ks);
var cycle = cljs.core.some(((function (q,sorted,in_degree__$1,unvisited,in_degree,ks){
return (function (p1__9136_SHARP_){
return re_frame.utils.find_cycle(graph,cljs.core.set(sorted),p1__9136_SHARP_);
});})(q,sorted,in_degree__$1,unvisited,in_degree,ks))
,unvisited);
throw (new Error((""+"Graph has a cycle: "+cljs.core.str.cljs$core$IFn$_invoke$arity$1(cycle))));

}
}
break;
}
});
re_frame.utils.remove_orphans = (function re_frame$utils$remove_orphans(graph){
return re_frame.utils.map_vals(cljs.core.partial.cljs$core$IFn$_invoke$arity$2(cljs.core.filterv,cljs.core.set(cljs.core.keys(graph))),graph);
});
re_frame.utils.safe_update_in = (function re_frame$utils$safe_update_in(var_args){
var args__5882__auto__ = [];
var len__5876__auto___9207 = arguments.length;
var i__5877__auto___9209 = (0);
while(true){
if((i__5877__auto___9209 < len__5876__auto___9207)){
args__5882__auto__.push((arguments[i__5877__auto___9209]));

var G__9210 = (i__5877__auto___9209 + (1));
i__5877__auto___9209 = G__9210;
continue;
} else {
}
break;
}

var argseq__5883__auto__ = ((((3) < args__5882__auto__.length))?(new cljs.core.IndexedSeq(args__5882__auto__.slice((3)),(0),null)):null);
return re_frame.utils.safe_update_in.cljs$core$IFn$_invoke$arity$variadic((arguments[(0)]),(arguments[(1)]),(arguments[(2)]),argseq__5883__auto__);
});

(re_frame.utils.safe_update_in.cljs$core$IFn$_invoke$arity$variadic = (function (m,path,f,args){
if(cljs.core.empty_QMARK_(path)){
return cljs.core.apply.cljs$core$IFn$_invoke$arity$3(f,m,args);
} else {
return cljs.core.apply.cljs$core$IFn$_invoke$arity$5(cljs.core.update_in,m,path,f,args);
}
}));

(re_frame.utils.safe_update_in.cljs$lang$maxFixedArity = (3));

/** @this {Function} */
(re_frame.utils.safe_update_in.cljs$lang$applyTo = (function (seq9164){
var G__9165 = cljs.core.first(seq9164);
var seq9164__$1 = cljs.core.next(seq9164);
var G__9166 = cljs.core.first(seq9164__$1);
var seq9164__$2 = cljs.core.next(seq9164__$1);
var G__9167 = cljs.core.first(seq9164__$2);
var seq9164__$3 = cljs.core.next(seq9164__$2);
var self__5861__auto__ = this;
return self__5861__auto__.cljs$core$IFn$_invoke$arity$variadic(G__9165,G__9166,G__9167,seq9164__$3);
}));

/**
 * Dissoces the map entry at the path, then recurs through the ancestors,
 *   dissocing each ancestor until one is found with a descendent outside the path.
 * 
 *   ```
 *   (deep-dissoc {:a {:b {:c {:d 1}}}}
 *             [:a :b :c :d])
 *   ```
 * 
 *   This yields an empty map, since each node has a sole descendant.
 * 
 *   ```
 *   (deep-dissoc {:a {:x 2 :b {:c {:d 1}}}}
 *             [:a :b :c :d])
 *   ```
 * 
 *   This yields `{:a {:x 2}}`, since `:a` has a descendent `:x` outside the path.
 *   
 */
re_frame.utils.deep_dissoc = (function re_frame$utils$deep_dissoc(m,path){
while(true){
if(cljs.core.empty_QMARK_(path)){
return m;
} else {
var new_data = re_frame.utils.safe_update_in.cljs$core$IFn$_invoke$arity$variadic(m,cljs.core.pop(path),cljs.core.dissoc,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([cljs.core.peek(path)], 0));
if((!(cljs.core.empty_QMARK_(cljs.core.get_in.cljs$core$IFn$_invoke$arity$2(new_data,cljs.core.pop(path)))))){
return new_data;
} else {
var G__9215 = new_data;
var G__9216 = cljs.core.pop(path);
m = G__9215;
path = G__9216;
continue;
}
}
break;
}
});

//# sourceMappingURL=re_frame.utils.js.map
