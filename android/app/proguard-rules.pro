# UniFFI bindings call the Rust library through JNA (SPEC.md 5.3).
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class com.sealctl.core.** { *; }
-dontwarn java.awt.**
