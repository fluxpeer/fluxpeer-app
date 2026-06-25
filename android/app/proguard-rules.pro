# WorkManager is initialized through AndroidX Startup and instantiates its
# Room-backed WorkDatabase and Worker classes through generated/reflection paths.
-keep class androidx.work.** { *; }
-keep class androidx.startup.** { *; }
-keep class androidx.room.** { *; }
-keep class androidx.sqlite.** { *; }
-keep class androidx.arch.core.** { *; }

-keep class * extends androidx.work.Worker { *; }
-keep class * extends androidx.work.ListenableWorker { *; }
-keep class dev.fluxpeer.fluxpeer.WatchdogWorker { *; }

-keep class androidx.startup.InitializationProvider { *; }
-keep class androidx.work.impl.WorkManagerInitializer { *; }
-keep class androidx.work.WorkManagerInitializer { *; }
-keep class androidx.work.impl.WorkDatabase { *; }

# Rust engines call into app classes via JNI and Android looks up native methods
# by their unmangled Java/Kotlin names. These members may otherwise look unused
# to R8 because the calls originate in libfp_node_*.
-keep class dev.fluxpeer.fluxpeer.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}
-keepclassmembers class dev.fluxpeer.fluxpeer.FluxpeerNode {
    public static boolean protectSocket(int);
    public static void onEngineExit();
    public static native java.lang.String runNode(java.lang.String, int);
    public static native void stopNode();
}
