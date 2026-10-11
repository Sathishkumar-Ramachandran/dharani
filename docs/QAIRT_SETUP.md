# On-device NPU speech recognition (Snapdragon 8 Elite Gen 5, SM8850)

No Qualcomm login or SDK install is needed. Everything comes from public sources:

| Piece | Source | How it gets on the phone |
|---|---|---|
| ONNX Runtime with QNN execution provider (1.29.0) | Maven Central `com.microsoft.onnxruntime:onnxruntime-android-qnn` | bundled in the APK (Gradle dependency) |
| Qualcomm QNN/QAIRT runtime libs (2.42.0, HTP v81 stub/skel) | Maven Central `com.qualcomm.qti:qnn-runtime` | bundled in the APK (Gradle dependency) |
| Whisper-Small compiled for SM8850 (520 MB, QAIRT 2.42) | Qualcomm AI Hub public assets (release v0.55.0) | **downloaded by the app** when you tap *Download & enable* |
| Whisper tokenizer (2.4 MB) | Hugging Face `openai/whisper-small` | downloaded by the app |

The runtime is bundled (not downloaded) on purpose: Android only lets an app load native libraries it ships in the
APK, and the Hexagon loader needs them as real files. The model list with URLs, sizes and SHA-256 checksums is
`mobile-ui/assets/ai_pack.json`; the app refuses any file whose checksum differs.

## Version pairing matters
The model's QAIRT version, ONNX Runtime's QNN build and the runtime libs must agree. Maven's ONNX Runtime 1.29 was built
against QAIRT 2.42, so the v0.55.0 model (also 2.42) is used. The newer v0.64.0 model needs QAIRT 2.50 + ORT 1.30,
which is not on Maven yet.

## Things that bit us (all in the code now)
- `AndroidManifest.xml` must declare `<uses-native-library android:name="libcdsprpc.so" android:required="false"/>`;
  without it Android 12+ hides the FastRPC library and QNN fails with `QNN_DEVICE_ERROR_INVALID_CONFIG`.
- `jniLibs.useLegacyPackaging = true` and `android:extractNativeLibs="true"` so the QNN libs exist as files.
- `ADSP_LIBRARY_PATH` must include the app's native library directory (set in `AiRuntime.prepareEnvironment`).

## Measured on your phone (vivo I2501, SM8850)
Encoder 30 s window: ~230 ms; model load: ~600 ms; 16 tokens decode: ~450 ms.
Hindi speech -> Devanagari text, and Hindi -> English via Whisper's translate task, both verified.

## Scope
NPU: speech recognition (and speech -> English translation). Translation to other Indian languages and the spoken
output still use ML Kit and Android TTS (no ready NPU models exist for them). Pipeline: mic -> **NPU Whisper** -> ML Kit -> TTS.
