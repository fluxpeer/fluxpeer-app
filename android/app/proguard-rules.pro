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
