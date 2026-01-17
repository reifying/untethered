goog.provide('voice_code.json');
/**
 * Convert kebab-case keyword to snake_case keyword.
 * Example: :session-id -> :session_id
 */
voice_code.json.kebab__GT_snake = (function voice_code$json$kebab__GT_snake(k){
if((k instanceof cljs.core.Keyword)){
return cljs.core.keyword.cljs$core$IFn$_invoke$arity$1(clojure.string.replace(cljs.core.name(k),"-","_"));
} else {
return k;
}
});
/**
 * Convert snake_case keyword to kebab-case keyword.
 * Example: :session_id -> :session-id
 */
voice_code.json.snake__GT_kebab = (function voice_code$json$snake__GT_kebab(k){
if((k instanceof cljs.core.Keyword)){
return cljs.core.keyword.cljs$core$IFn$_invoke$arity$1(clojure.string.replace(cljs.core.name(k),"_","-"));
} else {
return k;
}
});
/**
 * Recursively transform all keys in a map using function f.
 */
voice_code.json.transform_keys = (function voice_code$json$transform_keys(f,m){
return clojure.walk.postwalk((function (x){
if(cljs.core.map_QMARK_(x)){
return cljs.core.into.cljs$core$IFn$_invoke$arity$2(cljs.core.PersistentArrayMap.EMPTY,cljs.core.map.cljs$core$IFn$_invoke$arity$2((function (p__11012){
var vec__11014 = p__11012;
var k = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11014,(0),null);
var v = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11014,(1),null);
return new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [(f.cljs$core$IFn$_invoke$arity$1 ? f.cljs$core$IFn$_invoke$arity$1(k) : f.call(null,k)),v], null);
}),x));
} else {
return x;
}
}),m);
});
/**
 * Convert all keywords to strings in a map (recursively).
 */
voice_code.json.stringify_keys = (function voice_code$json$stringify_keys(m){
return clojure.walk.postwalk((function (x){
if(cljs.core.map_QMARK_(x)){
return cljs.core.into.cljs$core$IFn$_invoke$arity$2(cljs.core.PersistentArrayMap.EMPTY,cljs.core.map.cljs$core$IFn$_invoke$arity$2((function (p__11023){
var vec__11024 = p__11023;
var k = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11024,(0),null);
var v = cljs.core.nth.cljs$core$IFn$_invoke$arity$3(vec__11024,(1),null);
return new cljs.core.PersistentVector(null, 2, 5, cljs.core.PersistentVector.EMPTY_NODE, [(((k instanceof cljs.core.Keyword))?cljs.core.name(k):k),v], null);
}),x));
} else {
return x;
}
}),m);
});
/**
 * Convert Clojure map to JSON string with snake_case keys.
 * Used for outbound WebSocket messages.
 */
voice_code.json.clj__GT_json = (function voice_code$json$clj__GT_json(m){
var snake_keys = voice_code.json.transform_keys(voice_code.json.kebab__GT_snake,m);
var string_keys = voice_code.json.stringify_keys(snake_keys);
var js_obj = cljs.core.clj__GT_js(string_keys);
return JSON.stringify(js_obj);
});
/**
 * Parse JSON string to Clojure map with kebab-case keys.
 * Used for inbound WebSocket messages.
 */
voice_code.json.json__GT_clj = (function voice_code$json$json__GT_clj(s){
var parsed = JSON.parse(s);
var clj_map = cljs.core.js__GT_clj.cljs$core$IFn$_invoke$arity$variadic(parsed,cljs.core.prim_seq.cljs$core$IFn$_invoke$arity$2([new cljs.core.Keyword(null,"keywordize-keys","keywordize-keys",1310784252),true], 0));
var kebab_map = voice_code.json.transform_keys(voice_code.json.snake__GT_kebab,clj_map);
return kebab_map;
});
/**
 * Parse JSON string safely, returning nil on error.
 */
voice_code.json.parse_json_safe = (function voice_code$json$parse_json_safe(s){
try{return voice_code.json.json__GT_clj(s);
}catch (e11029){var _ = e11029;
return null;
}});

//# sourceMappingURL=voice_code.json.js.map
