-keep class com.jcraft.**  { *; }
-keep class io.flutter.util.PathUtils { *; }

# Wireless ADB calls Conscrypt reflectively.
-keep class org.conscrypt.** { *; }
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**

# Screen control waits for libadb's write-ready flag (AdbWriteGate) by name.
-keepclassmembers class io.github.muntashirakon.adb.AdbStream {
    java.util.concurrent.atomic.AtomicBoolean mWriteReady;
}
