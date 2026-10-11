package com.dharani.dharani_mobile

import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Handler
import android.os.Looper

class MainActivity : FlutterActivity() {
    private var callAudio: CallAudio? = null
    private var micSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    private var textSink: io.flutter.plugin.common.EventChannel.EventSink? = null
    private var npu: WhisperNpu? = null
    private val npuLock = Any()
    private val capture = AudioCapture()
    private var micResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // An offer or call may open the app over the lock screen and turn the display on.
        if (Build.VERSION.SDK_INT >= 27) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
        // Loading here (before Dart opens the same library through dart:ffi) makes a missing or
        // mismatched libdharani_ffi.so show up in logcat with a clear message.
        try {
            System.loadLibrary("dharani_ffi")
            Log.i("Dharani", "native core loaded: " + NativeInfo.version())
        } catch (e: UnsatisfiedLinkError) {
            Log.e("Dharani", "native core failed to load", e)
        }
        // Developer hook: with files/asr_test.wav present, transcribe it on the NPU and write files/asr_test.log.
        val wav = java.io.File(filesDir, "asr_test.wav")
        if (wav.exists()) {
            Thread {
                val log = java.io.File(filesDir, "asr_test.log")
                try {
                    val opts = java.io.File(filesDir, "asr_test.opts").takeIf { it.exists() }?.readText()?.trim()?.split(" ") ?: listOf("en", "transcribe")
                    val bytes = wav.readBytes()
                    val pcm = FloatArray((bytes.size - 44) / 2)
                    val bb = java.nio.ByteBuffer.wrap(bytes, 44, bytes.size - 44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
                    for (i in pcm.indices) pcm[i] = bb.short / 32768f
                    val t0 = System.nanoTime()
                    val engine = npu ?: WhisperNpu.load(applicationContext, java.io.File(filesDir, "models/runtime/whisper-small-sm8850"), java.io.File(filesDir, "models/whisper-tokenizer.bin")).also { npu = it }
                    val loadMs = (System.nanoTime() - t0) / 1_000_000
                    val r = engine.transcribe(pcm, opts[0], opts.getOrNull(1) == "translate")
                    log.writeText("load=${loadMs}ms mel=${r.melMs}ms encoder=${r.encoderMs}ms decode=${r.decodeMs}ms tokens=${r.tokens}\nTEXT: ${r.text}\n")
                } catch (t: Throwable) {
                    log.writeText("FAILED: $t\n" + android.util.Log.getStackTraceString(t))
                }
            }.start()
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 4711) {
            micResult?.success(grantResults.isNotEmpty() && grantResults[0] == android.content.pm.PackageManager.PERMISSION_GRANTED)
            micResult = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dharani/keepalive").setMethodCallHandler { call, result ->
            val svc = Intent(this, KeepAliveService::class.java)
            when (call.method) {
                "start" -> {
                    if (android.os.Build.VERSION.SDK_INT >= 33 && checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 4713)
                    }
                    svc.putExtra("text", call.argument<String>("text"))
                    try {
                        if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(svc) else startService(svc)
                        result.success(true)
                    } catch (t: Throwable) {
                        Log.e("Dharani", "keep-alive start failed", t)
                        result.success(false)
                    }
                }
                "stop" -> {
                    stopService(svc)
                    result.success(true)
                }
                "alert" -> {
                    // Incoming ride offer / call while the screen is off or another app is open: heads-up
                    // notification with a full-screen intent (opens the app over the lock screen) + wake the display.
                    try {
                        val nm = getSystemService(android.app.NotificationManager::class.java)
                        val ch = android.app.NotificationChannel("dharani_alert", "Ride requests & calls", android.app.NotificationManager.IMPORTANCE_HIGH)
                        ch.enableVibration(true)
                        ch.lockscreenVisibility = android.app.Notification.VISIBILITY_PUBLIC
                        nm.createNotificationChannel(ch)
                        val open = android.app.PendingIntent.getActivity(
                            this, 0,
                            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                            android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
                        )
                        val n = android.app.Notification.Builder(this, "dharani_alert")
                            .setSmallIcon(applicationInfo.icon)
                            .setContentTitle(call.argument<String>("title"))
                            .setContentText(call.argument<String>("text"))
                            .setCategory(android.app.Notification.CATEGORY_CALL)
                            .setContentIntent(open)
                            .setFullScreenIntent(open, true)
                            .setAutoCancel(true)
                            .build()
                        nm.notify(4713, n)
                        val pm = getSystemService(android.os.PowerManager::class.java)
                        @Suppress("DEPRECATION")
                        pm.newWakeLock(android.os.PowerManager.SCREEN_BRIGHT_WAKE_LOCK or android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP, "dharani:alert").acquire(8000)
                        result.success(true)
                    } catch (t: Throwable) {
                        Log.e("Dharani", "alert failed", t)
                        result.success(false)
                    }
                }
                "clearAlert" -> {
                    getSystemService(android.app.NotificationManager::class.java).cancel(4713)
                    result.success(true)
                }
                "batteryExempt" -> {
                    val pm = getSystemService(android.os.PowerManager::class.java)
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestBatteryExempt" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, android.net.Uri.parse("package:$packageName")))
                        result.success(true)
                    } catch (t: Throwable) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dharani/ai").setMethodCallHandler { call, result ->
            val main = Handler(Looper.getMainLooper())
            fun async(block: () -> Any?) = Thread {
                try {
                    val r = block()
                    main.post { result.success(r) }
                } catch (t: Throwable) {
                    Log.e("DharaniAI", call.method, t)
                    main.post { result.error("npu", t.message ?: t.toString(), null) }
                }
            }.start()
            when (call.method) {
                "status" -> {
                    val libDir = java.io.File(applicationInfo.nativeLibraryDir)
                    result.success(mapOf(
                        "runtimeBundled" to (java.io.File(libDir, "libQnnHtp.so").exists() && java.io.File(libDir, "libonnxruntime.so").exists()),
                        "loaded" to (npu != null),
                    ))
                }
                "ensureMic" -> {
                    if (checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) == android.content.pm.PackageManager.PERMISSION_GRANTED) {
                        result.success(true)
                    } else {
                        micResult = result
                        requestPermissions(arrayOf(android.Manifest.permission.RECORD_AUDIO), 4711)
                    }
                }
                "load" -> async {
                    synchronized(npuLock) {
                        if (npu != null) return@async 0L // already loaded: never reload under a running call
                        val t0 = System.nanoTime()
                        npu = WhisperNpu.load(applicationContext, java.io.File(filesDir, "models/runtime/whisper-small-sm8850"), java.io.File(filesDir, "models/whisper-tokenizer.bin"))
                        (System.nanoTime() - t0) / 1_000_000
                    }
                }
                "unzip" -> async {
                    val src = java.io.File(call.argument<String>("src")!!)
                    val dst = java.io.File(call.argument<String>("dst")!!)
                    dst.mkdirs()
                    val root = dst.canonicalPath + java.io.File.separator
                    java.util.zip.ZipInputStream(src.inputStream().buffered(1 shl 20)).use { zin ->
                        var e = zin.nextEntry
                        while (e != null) {
                            val out = java.io.File(dst, e.name)
                            if (!out.canonicalPath.startsWith(root)) throw SecurityException("zip entry escapes target: ${e.name}")
                            if (e.isDirectory) out.mkdirs() else {
                                out.parentFile?.mkdirs()
                                out.outputStream().buffered(1 shl 20).use { zin.copyTo(it) }
                            }
                            e = zin.nextEntry
                        }
                    }
                    true
                }
                "release" -> { synchronized(npuLock) { npu?.close(); npu = null }; result.success(null) }
                "stopRecording" -> { capture.stop(); result.success(null) }
                "listen" -> async {
                    val engine = npu ?: throw IllegalStateException("NPU model is not loaded")
                    val lang = call.argument<String>("lang") ?: "en"
                    val translate = call.argument<Boolean>("translate") ?: false
                    val max = call.argument<Int>("maxSeconds") ?: 25
                    val t0 = System.nanoTime()
                    val pcm = capture.record(max)
                    val recMs = (System.nanoTime() - t0) / 1_000_000
                    if (pcm.isEmpty()) mapOf("text" to "", "recordMs" to recMs)
                    else {
                        val r = engine.transcribe(pcm, lang, translate)
                        mapOf("text" to r.text, "recordMs" to recMs, "melMs" to r.melMs, "encoderMs" to r.encoderMs, "decodeMs" to r.decodeMs, "tokens" to r.tokens)
                    }
                }
                else -> result.notImplemented()
            }
        }
        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger, "dharani/call/mic").setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: io.flutter.plugin.common.EventChannel.EventSink?) { micSink = sink }
            override fun onCancel(args: Any?) { micSink = null }
        })
        io.flutter.plugin.common.EventChannel(flutterEngine.dartExecutor.binaryMessenger, "dharani/call/text").setStreamHandler(object : io.flutter.plugin.common.EventChannel.StreamHandler {
            override fun onListen(args: Any?, sink: io.flutter.plugin.common.EventChannel.EventSink?) { textSink = sink }
            override fun onCancel(args: Any?) { textSink = null }
        })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dharani/call").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "start" -> {
                        val ca = callAudio ?: CallAudio(applicationContext) { npu }.also { callAudio = it }
                        ca.start(
                            speaker = call.argument<Boolean>("speaker") ?: false,
                            relayRaw = call.argument<Boolean>("relayRaw") ?: true,
                            translateLang = call.argument<String>("translateLang"),
                            onFrame = { frame -> micSink?.success(frame) },
                            onText = { text, ms -> textSink?.success(mapOf("text" to text, "ms" to ms)) },
                        )
                        result.success(null)
                    }
                    "play" -> { callAudio?.play(call.argument<ByteArray>("pcm")!!); result.success(null) }
                    "configure" -> {
                        callAudio?.relayRaw = call.argument<Boolean>("relayRaw") ?: true
                        callAudio?.translateLang = call.argument<String>("translateLang")
                        result.success(null)
                    }
                    "gate" -> { callAudio?.gate = call.argument<Boolean>("gate") ?: false; result.success(null) }
                    "mute" -> { callAudio?.muted = call.argument<Boolean>("muted") ?: false; result.success(null) }
                    "speaker" -> { callAudio?.setSpeaker(call.argument<Boolean>("on") ?: false); result.success(null) }
                    "stats" -> result.success(callAudio?.let { mapOf("captured" to it.framesCaptured, "played" to it.framesPlayed, "dropped" to it.framesDropped) } ?: mapOf<String, Long>())
                    "stop" -> { callAudio?.stop(); result.success(null) }
                    else -> result.notImplemented()
                }
            } catch (t: Throwable) {
                Log.e("DharaniCall", call.method, t)
                result.error("call", t.message ?: t.toString(), null)
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dharani/device").setMethodCallHandler { call, result ->
            if (call.method != "info") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val info = HashMap<String, Any?>()
            info["model"] = Build.MODEL
            info["manufacturer"] = Build.MANUFACTURER
            info["hardware"] = Build.HARDWARE
            info["board"] = Build.BOARD
            info["sdk"] = Build.VERSION.SDK_INT
            info["abis"] = Build.SUPPORTED_ABIS.toList()
            if (Build.VERSION.SDK_INT >= 31) {
                info["socManufacturer"] = Build.SOC_MANUFACTURER
                info["socModel"] = Build.SOC_MODEL
            }
            result.success(info)
        }
    }
}
