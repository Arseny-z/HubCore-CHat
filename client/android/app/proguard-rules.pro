# SQLCipher — keep native handle field required by JNI
-keep class net.sqlcipher.** { *; }
-keep class net.sqlcipher.database.** { *; }

# gomobile / hubcorebind — keep all exported Go types
-keep class hubcorebind.** { *; }
-keep class rnsbind.** { *; }
-keep class yggbind.** { *; }
