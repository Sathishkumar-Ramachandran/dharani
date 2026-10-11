package com.dharani.dharani_mobile

import java.util.stream.IntStream
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.exp

/** Whisper log-mel front end: 16 kHz mono -> [80 x 3000] features for a 30 s window. */
object MelSpectrogram {
    const val SAMPLE_RATE = 16000
    const val N_FFT = 400
    const val HOP = 160
    const val N_MELS = 80
    const val N_SAMPLES = 30 * SAMPLE_RATE
    const val N_FRAMES = 3000
    private const val N_BINS = N_FFT / 2 + 1

    private val window = FloatArray(N_FFT) { (0.5 - 0.5 * cos(2.0 * PI * it / N_FFT)).toFloat() } // periodic Hann
    private val cosTable = FloatArray(N_BINS * N_FFT)
    private val sinTable = FloatArray(N_BINS * N_FFT)
    private val filters = Array(N_MELS) { FloatArray(N_BINS) }

    init {
        for (k in 0 until N_BINS) for (n in 0 until N_FFT) {
            val a = 2.0 * PI * k * n / N_FFT
            cosTable[k * N_FFT + n] = cos(a).toFloat()
            sinTable[k * N_FFT + n] = sin(a).toFloat()
        }
        buildMelFilters()
    }

    // Slaney mel scale with Slaney normalisation (librosa defaults, as used by Whisper).
    private fun hzToMel(f: Double): Double {
        val fSp = 200.0 / 3
        val minLogHz = 1000.0
        val minLogMel = minLogHz / fSp
        val logStep = ln(6.4) / 27.0
        return if (f >= minLogHz) minLogMel + ln(f / minLogHz) / logStep else f / fSp
    }

    private fun melToHz(m: Double): Double {
        val fSp = 200.0 / 3
        val minLogHz = 1000.0
        val minLogMel = minLogHz / fSp
        val logStep = ln(6.4) / 27.0
        return if (m >= minLogMel) minLogHz * exp(logStep * (m - minLogMel)) else fSp * m
    }

    private fun buildMelFilters() {
        val fMax = SAMPLE_RATE / 2.0
        val melMin = hzToMel(0.0)
        val melMax = hzToMel(fMax)
        val points = DoubleArray(N_MELS + 2) { melToHz(melMin + (melMax - melMin) * it / (N_MELS + 1)) }
        val fft = DoubleArray(N_BINS) { it * SAMPLE_RATE.toDouble() / N_FFT }
        for (m in 0 until N_MELS) {
            val lo = points[m]
            val mid = points[m + 1]
            val hi = points[m + 2]
            val enorm = 2.0 / (hi - lo)
            for (k in 0 until N_BINS) {
                val lower = (fft[k] - lo) / (mid - lo)
                val upper = (hi - fft[k]) / (hi - mid)
                filters[m][k] = (max(0.0, min(lower, upper)) * enorm).toFloat()
            }
        }
    }

    /** `pcm` is mono float in [-1, 1] at 16 kHz; it is zero padded or cut to 30 s. */
    fun compute(pcm: FloatArray): FloatArray {
        val audio = FloatArray(N_SAMPLES)
        System.arraycopy(pcm, 0, audio, 0, min(pcm.size, N_SAMPLES))

        // torch.stft(center=True): reflect pad N_FFT/2 on both sides.
        val pad = N_FFT / 2
        val padded = FloatArray(N_SAMPLES + 2 * pad)
        System.arraycopy(audio, 0, padded, pad, N_SAMPLES)
        for (i in 0 until pad) {
            padded[pad - 1 - i] = audio[i + 1]
            padded[pad + N_SAMPLES + i] = audio[N_SAMPLES - 2 - i]
        }

        val power = Array(N_FRAMES) { FloatArray(N_BINS) }
        IntStream.range(0, N_FRAMES).parallel().forEach { f ->
            val x = FloatArray(N_FFT)
            val base = f * HOP
            for (n in 0 until N_FFT) x[n] = padded[base + n] * window[n]
            val p = power[f]
            for (k in 0 until N_BINS) {
                var re = 0f
                var im = 0f
                val off = k * N_FFT
                for (n in 0 until N_FFT) {
                    re += x[n] * cosTable[off + n]
                    im -= x[n] * sinTable[off + n]
                }
                p[k] = re * re + im * im
            }
        }

        val out = FloatArray(N_MELS * N_FRAMES)
        var maxLog = -1e30f
        for (m in 0 until N_MELS) {
            val fm = filters[m]
            for (f in 0 until N_FRAMES) {
                val p = power[f]
                var s = 0f
                for (k in 0 until N_BINS) s += fm[k] * p[k]
                val v = kotlin.math.log10(max(s, 1e-10f))
                out[m * N_FRAMES + f] = v
                if (v > maxLog) maxLog = v
            }
        }
        val floor = maxLog - 8f
        for (i in out.indices) out[i] = (max(out[i], floor) + 4f) / 4f
        return out
    }
}
