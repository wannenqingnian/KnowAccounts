# ONNX Runtime JNI uses FindClass/GetMethodID/GetFieldID with fixed Java names.
# The Android 1.23.2 AAR supplies no consumer rules. Keep implementations and
# members, not only native methods: TensorInfo([J, String[], int) is called only
# from libonnxruntime4j_jni.so and would otherwise be removed by R8.
-keep class ai.onnxruntime.** { *; }

# OpenCV's Android AAR also has no consumer rules. Its native wrappers access
# Java classes/members by name; retain the bridge while shrinking app code.
-keep class org.opencv.** { *; }

# sherpa-onnx JNI reads Kotlin config fields and creates result objects using
# fixed class/member names. Keeping native methods alone is insufficient: R8
# would rename OfflineModelConfig/SileroVadModelConfig fields in release builds.
-keep class com.k2fsa.sherpa.onnx.** { *; }
