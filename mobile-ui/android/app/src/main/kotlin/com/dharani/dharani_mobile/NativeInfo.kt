package com.dharani.dharani_mobile

/** JNI entry points exported by ffi-bridge/android/jni_dharani_bridge.cpp. */
object NativeInfo {
    @JvmStatic external fun version(): String
    @JvmStatic external fun shutdown(): Int
}
