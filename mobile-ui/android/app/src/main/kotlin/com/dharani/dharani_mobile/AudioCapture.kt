package com.dharani.dharani_mobile

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlin.math.abs

/** Records 16 kHz mono speech and stops after a pause (simple energy VAD), a limit, or stop(). */
class AudioCapture {
    @Volatile private var stopRequested = false

    fun stop() { stopRequested = true }

    @SuppressLint("MissingPermission")
    fun record(maxSeconds: Int, silenceMs: Int = 1400): FloatArray {
        stopRequested = false
        val rate = MelSpectrogram.SAMPLE_RATE
        val minBuf = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, rate))
        if (rec.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("Microphone could not be opened")
        val out = FloatArray(rate * maxSeconds)
        var n = 0
        val chunk = ShortArray(rate / 10)
        var heardSpeech = false
        var quietChunks = 0
        var noise = 0.004f
        try {
            rec.startRecording()
            while (!stopRequested && n + chunk.size <= out.size) {
                val r = rec.read(chunk, 0, chunk.size)
                if (r <= 0) break
                var energy = 0f
                for (i in 0 until r) {
                    val f = chunk[i] / 32768f
                    out[n + i] = f
                    energy += abs(f)
                }
                n += r
                energy /= r
                if (!heardSpeech) noise = 0.9f * noise + 0.1f * energy
                val loud = energy > maxOf(0.015f, noise * 3f)
                if (loud) { heardSpeech = true; quietChunks = 0 } else if (heardSpeech) quietChunks++
                if (heardSpeech && quietChunks * 100 >= silenceMs) break
            }
        } finally {
            rec.stop()
            rec.release()
        }
        return if (heardSpeech) out.copyOf(n) else FloatArray(0)
    }
}
