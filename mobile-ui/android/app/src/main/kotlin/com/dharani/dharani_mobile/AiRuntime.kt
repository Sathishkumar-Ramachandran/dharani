package com.dharani.dharani_mobile

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import android.system.Os
import android.util.Log
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Runs precompiled QNN (Hexagon NPU) models through ONNX Runtime's QNN execution provider. */
object AiRuntime {
    private const val TAG = "DharaniAI"

    /** Points the Hexagon loader at the app's native libraries (stub/skel live there). */
    fun prepareEnvironment(context: Context) {
        val libDir = context.applicationInfo.nativeLibraryDir
        val path = "$libDir;/vendor/lib/rfsa/adsp;/vendor/dsp/cdsp;/system/lib/rfsa/adsp"
        Os.setenv("ADSP_LIBRARY_PATH", path, true)
        Os.setenv("LD_LIBRARY_PATH", "$libDir:" + (System.getenv("LD_LIBRARY_PATH") ?: ""), true)
    }

    fun newSession(env: OrtEnvironment, modelPath: String): OrtSession {
        val opts = OrtSession.SessionOptions()
        opts.addConfigEntry("session.disable_cpu_ep_fallback", "1") // fail loudly instead of silently using the CPU
        opts.addQnn(mapOf("backend_path" to "libQnnHtp.so"))
        return env.createSession(modelPath, opts)
    }

    /** Loads the encoder on the NPU, runs one zero input, and reports timing. Returns a log. */
    fun selfTest(context: Context, modelDir: String): String {
        val log = StringBuilder()
        fun say(s: String) {
            Log.i(TAG, s)
            log.appendLine(s)
        }
        try {
            prepareEnvironment(context)
            say("nativeLibraryDir=" + context.applicationInfo.nativeLibraryDir)
            say("libs: " + File(context.applicationInfo.nativeLibraryDir).list()?.filter { it.contains("Qnn") || it.contains("onnx") }?.sorted())
            val env = OrtEnvironment.getEnvironment(ai.onnxruntime.OrtLoggingLevel.ORT_LOGGING_LEVEL_VERBOSE, "dharani")
            say("providers: " + OrtEnvironment.getAvailableProviders())
            // Models live in app-private storage (the app downloads them there).
            val local = File(context.filesDir, "whisper")
            say("model dir ${local.path}: ${local.list()?.sorted()}")
            val t0 = System.nanoTime()
            val session = newSession(env, File(local, "encoder.onnx").path)
            say("encoder session created in ${(System.nanoTime() - t0) / 1_000_000} ms; inputs=${session.inputNames} outputs=${session.outputNames.size}")
            val shape = longArrayOf(1, 80, 3000)
            val buf = ByteBuffer.allocateDirect(80 * 3000 * 2).order(ByteOrder.nativeOrder())
            val input = OnnxTensor.createTensor(env, buf, shape, OnnxJavaType.FLOAT16)
            for (i in 0 until 3) {
                val t1 = System.nanoTime()
                val out = session.run(mapOf("input_features" to input))
                say("run $i: ${(System.nanoTime() - t1) / 1_000_000} ms, outputs=${out.size()}")
                out.close()
            }
            input.close()
            session.close()
            say("SELFTEST OK")
        } catch (t: Throwable) {
            say("SELFTEST FAILED: $t")
            Log.e(TAG, "selftest", t)
        }
        return log.toString()
    }
}
