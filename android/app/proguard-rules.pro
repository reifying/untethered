# ProGuard rules for VoiceCode Android

# Keep Kotlin serialization
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt

-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep VoiceCode data models
-keep,includedescriptorclasses class dev.labs910.voicecode.data.model.**$$serializer { *; }
-keepclassmembers class dev.labs910.voicecode.data.model.** {
    *** Companion;
}
-keepclasseswithmembers class dev.labs910.voicecode.data.model.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep Room entities
-keep class dev.labs910.voicecode.data.local.** { *; }

# OkHttp
-dontwarn okhttp3.**
-dontwarn okio.**
-keepnames class okhttp3.internal.publicsuffix.PublicSuffixDatabase

# Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}
-keepclassmembers class kotlinx.coroutines.** {
    volatile <fields>;
}
