// Thin JNI surface so Kotlin/Java host code can query the native library without going through
// dart:ffi (for example from a foreground service). Flutter itself binds the C ABI directly.
#include <jni.h>

#include "../dharani_c_api.h"

extern "C" JNIEXPORT jstring JNICALL Java_com_dharani_dharani_1mobile_NativeInfo_version(JNIEnv* env, jclass) {
  return env->NewStringUTF(dharani_version());
}

extern "C" JNIEXPORT jint JNICALL Java_com_dharani_dharani_1mobile_NativeInfo_shutdown(JNIEnv*, jclass) {
  return dharani_engine_shutdown().code;
}
