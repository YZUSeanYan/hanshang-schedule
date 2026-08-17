# WorkManager/Room loads the generated database implementation by name.
# This exact class was removed by an earlier R8 build and caused startup crash.
-keep class androidx.work.impl.WorkDatabase_Impl { *; }

# Keep Room generated implementations used by Android libraries through reflection.
-keep class * extends androidx.room.RoomDatabase { *; }

# Flutter plugins are registered by generated Java code, but callback entrypoints
# may be invoked from Android framework components while Dart is detached.
-keep class com.aliyun.ams.push.** { *; }

# Aliyun's tnet can optionally use the separate android-netutil ping extension.
# The extension is not shipped by alicloud-android-push and tnet falls back when
# these classes are absent; suppress only the three optional references.
-dontwarn org.android.netutil.PingEntry
-dontwarn org.android.netutil.PingResponse
-dontwarn org.android.netutil.PingTask
