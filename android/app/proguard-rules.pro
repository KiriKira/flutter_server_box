-keep class com.jcraft.**  { *; }
-keep class io.flutter.util.PathUtils { *; }

# Wireless ADB calls Conscrypt reflectively.
-keep class org.conscrypt.** { *; }
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
