# proguard-rules.pro — R8 keep rules for the bare Hermes + JSI + JNI Canopy host.
#
# The whole point of these rules: the C1 native-module ABI and the JSI host reach Java
# classes/methods BY NAME from C++ (never via a Java reference R8 can trace), so R8 would
# strip or rename them and the app would crash at runtime (ClassNotFound / NoSuchMethod).
# Everything reached from native code must be kept verbatim.

# --- the entire host package: every class here is JNI/JSI-adjacent ---------------------
# C++ resolves capability modules by string ("com/canopyhost/modules/<Name>Module") and calls
# their static invoke(String,String,String); CanopyHostJni's static methods (emitEvent,
# resolveModule, onJsError, scheduleOnJs, reload, runJsCallback, current, appContext) are
# called from C++; the view classes are instantiated by the host. Keep them all + their members.
-keep class com.canopyhost.** { *; }

# --- JNI native method stubs (the C++ <-> Java bridge) --------------------------------
-keepclasseswithmembernames,includedescriptorclasses class * {
    native <methods>;
}

# --- Facebook native bindings (fbjni JNI_OnLoad, Yoga JNI, SoLoader) ------------------
-keep class com.facebook.jni.** { *; }
-keep class com.facebook.yoga.** { *; }
-keep class com.facebook.soloader.** { *; }
-dontwarn com.facebook.**

# --- androidx security-crypto + Tink (reflection-driven key schemes) ------------------
-keep class com.google.crypto.tink.** { *; }
-keep class androidx.security.crypto.** { *; }
-dontwarn com.google.crypto.tink.**
-dontwarn javax.annotation.**

# --- keep annotations + enclosing info so reflective lookups resolve ------------------
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# --- AndroidX ComponentActivity result/back machinery (used by MainActivity) ----------
-keep class androidx.activity.** { *; }
-keep class androidx.core.content.FileProvider { *; }

# --- Play Billing v6 (BillingModule paywall). The AAR ships consumer rules; pin defensively. ---
-keep class com.android.billingclient.api.** { *; }
-keep interface com.android.billingclient.api.** { *; }
-dontwarn com.android.billingclient.**
