package com.dharani.dharani_mobile

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AutomaticGainControl
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Full-duplex voice for a call: 16 kHz mono PCM16 in 20 ms frames (640 bytes).
 * Capture uses the VOICE_COMMUNICATION source with the platform echo canceller / noise suppressor;
 * playback is a small bounded jitter buffer so latency can never grow without limit.
 */
class CallAudio(private val context: Context, private val engine: () -> WhisperNpu?) {
    companion object {
        const val RATE = 16000
        const val FRAME_BYTES = 640
        private const val TAG = "DharaniCall"
        private const val MAX_QUEUED_FRAMES = 12 // 240 ms: older audio is dropped, not delayed
        private const val PREBUFFER_FRAMES = 3     // 60 ms before playback starts
    }

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var running = false
    @Volatile var muted = false

    /** When true, microphone frames are sent to the other phone as voice. Off in interpreter mode. */
    @Volatile var relayRaw = true

    /** Language of the local speaker; non-null means "transcribe my speech on the NPU" (interpreter mode). */
    @Volatile var translateLang: String? = null
    @Volatile var gate: Boolean = false
        set(v) { field = v; segmenter.gated = v }
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor { r -> Thread(r, "dharani-call-asr") }
    private val pending = java.util.concurrent.atomic.AtomicInteger(0)
    private var onText: ((String, Long) -> Unit)? = null
    private val segmenter = UtteranceSegmenter(onUtterance = { pcm -> transcribe(pcm) })
    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var effects = ArrayList<android.media.audiofx.AudioEffect>()
    private var micThread: Thread? = null
    private var playThread: Thread? = null
    private val playQueue = ArrayBlockingQueue<ByteArray>(MAX_QUEUED_FRAMES)
    private val injected = java.util.concurrent.ConcurrentLinkedQueue<ByteArray>()
    private var previousMode = AudioManager.MODE_NORMAL
    private var previousSpeaker = false

    @Volatile var framesCaptured = 0L
    @Volatile var framesPlayed = 0L
    @Volatile var framesDropped = 0L

    /** `onFrame` is called on the main thread with each 640-byte microphone frame (not called while muted). */
    @SuppressLint("MissingPermission")
    fun start(speaker: Boolean, relayRaw: Boolean, translateLang: String?, onFrame: (ByteArray) -> Unit, onText: (String, Long) -> Unit) {
        if (running) return
        this.relayRaw = relayRaw
        this.translateLang = translateLang
        this.onText = onText
        segmenter.reset()
        previousMode = audioManager.mode
        previousSpeaker = audioManager.isSpeakerphoneOn
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        setSpeaker(speaker)

        val minRec = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minRec, FRAME_BYTES * 8))
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            audioManager.mode = previousMode
            throw IllegalStateException("Microphone could not be opened for the call")
        }
        if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(rec.audioSessionId)?.let { it.enabled = true; effects.add(it) }
        if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(rec.audioSessionId)?.let { it.enabled = true; effects.add(it) }
        if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(rec.audioSessionId)?.let { it.enabled = true; effects.add(it) }
        record = rec

        val minPlay = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val t = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(RATE).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(maxOf(minPlay, FRAME_BYTES * 6))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
            .build()
        track = t

        playQueue.clear()
        framesCaptured = 0; framesPlayed = 0; framesDropped = 0
        running = true
        rec.startRecording()
        t.play()

        micThread = Thread({
            val buf = ByteArray(FRAME_BYTES)
            while (running) {
                var off = 0
                while (running && off < FRAME_BYTES) {
                    val r = rec.read(buf, off, FRAME_BYTES - off)
                    if (r <= 0) { running = false; break }
                    off += r
                }
                if (!running) break
                framesCaptured++
                // Developer hook: files/call_inject.wav (16 kHz mono PCM16) is played into the call as if spoken.
                if (framesCaptured % 25L == 0L) pickUpInjection()
                injected.poll()?.let { System.arraycopy(it, 0, buf, 0, FRAME_BYTES) }
                if (!muted) {
                    val copy = buf.copyOf()
                    if (relayRaw) main.post { onFrame(copy) }
                    if (translateLang != null) segmenter.feed(copy)
                }
            }
        }, "dharani-call-mic").also { it.priority = Thread.MAX_PRIORITY; it.start() }

        playThread = Thread({
            var primed = false
            while (running) {
                if (!primed) {
                    if (playQueue.size < PREBUFFER_FRAMES) { Thread.sleep(5); continue }
                    primed = true
                }
                val f = playQueue.poll(100, TimeUnit.MILLISECONDS)
                if (f == null) { primed = false; continue } // underrun: re-prime to avoid stutter
                t.write(f, 0, f.size)
                framesPlayed++
            }
        }, "dharani-call-play").also { it.priority = Thread.MAX_PRIORITY; it.start() }
        Log.i(TAG, "call audio started (speaker=$speaker, aec=${AcousticEchoCanceler.isAvailable()}, ns=${NoiseSuppressor.isAvailable()})")
    }

    private fun pickUpInjection() {
        val f = java.io.File(context.filesDir, "call_inject.wav")
        if (!f.exists()) return
        try {
            val bytes = f.readBytes()
            f.delete()
            var off = 44
            while (off + FRAME_BYTES <= bytes.size) {
                injected.add(bytes.copyOfRange(off, off + FRAME_BYTES))
                off += FRAME_BYTES
            }
            repeat(100) { injected.add(ByteArray(FRAME_BYTES)) } // 2 s of silence so the sentence is closed
            Log.i(TAG, "injecting ${injected.size} frames from call_inject.wav")
        } catch (t: Throwable) {
            Log.e(TAG, "inject failed", t)
        }
    }

    /** Runs speech recognition for one finished utterance on the NPU, one at a time; stale ones are skipped. */
    private fun transcribe(pcm: FloatArray) {
        val lang = translateLang ?: return
        val npu = engine() ?: return
        if (pending.get() >= 2) return // the NPU is behind: drop rather than fall further behind
        pending.incrementAndGet()
        worker.execute {
            try {
                val t0 = System.nanoTime()
                val r = npu.transcribe(pcm, lang, false)
                val text = r.text.trim()
                Log.i(TAG, "interpreter heard (${lang}): '${text}' in ${(System.nanoTime() - t0) / 1_000_000} ms")
                if (text.isNotEmpty() && running) main.post { onText?.invoke(text, (System.nanoTime() - t0) / 1_000_000) }
            } catch (t: Throwable) {
                Log.e(TAG, "interpreter transcribe failed", t)
            } finally {
                pending.decrementAndGet()
            }
        }
    }

    /** Queues one received frame. Never blocks: when the buffer is full the oldest audio is dropped. */
    fun play(frame: ByteArray) {
        if (!running) return
        while (!playQueue.offer(frame)) {
            playQueue.poll()
            framesDropped++
        }
    }

    fun setSpeaker(on: Boolean) {
        @Suppress("DEPRECATION")
        audioManager.isSpeakerphoneOn = on
    }

    fun stop() {
        if (!running && record == null) return
        running = false
        try { micThread?.join(300) } catch (_: InterruptedException) {}
        try { playThread?.join(300) } catch (_: InterruptedException) {}
        record?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        track?.let { try { it.stop() } catch (_: Exception) {}; it.release() }
        effects.forEach { try { it.release() } catch (_: Exception) {} }
        effects.clear()
        record = null; track = null
        audioManager.mode = previousMode
        audioManager.isSpeakerphoneOn = previousSpeaker
        Log.i(TAG, "call audio stopped: captured=$framesCaptured played=$framesPlayed dropped=$framesDropped")
    }
}
