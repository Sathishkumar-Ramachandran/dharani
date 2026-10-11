package com.dharani.dharani_mobile

import kotlin.math.abs
import kotlin.math.max

/**
 * Splits a continuous 16 kHz microphone stream into utterances with an adaptive energy detector.
 * Feed it 20 ms frames; it calls [onUtterance] with the speech (plus a little lead-in) after a pause.
 */
class UtteranceSegmenter(
    private val onUtterance: (FloatArray) -> Unit,
    private val frameSamples: Int = 320,
    private val silenceFramesToEnd: Int = 36,    // 720 ms: fast speakers pause briefly mid-sentence
    private val maxUtteranceFrames: Int = 1000,  // 20 s
    private val minSpeechFrames: Int = 15,       // 300 ms
    private val preRollFrames: Int = 10,         // 200 ms
) {
    private var noiseFloor = 0.004f
    private var inSpeech = false
    private var silentRun = 0
    private var speechFrames = 0
    private val preRoll = ArrayDeque<FloatArray>()
    private val current = ArrayList<FloatArray>()

    /** Frames received while the other side's voice is playing are ignored (our mic would hear the speaker). */
    @Volatile var gated = false

    fun reset() {
        inSpeech = false
        silentRun = 0
        speechFrames = 0
        preRoll.clear()
        current.clear()
    }

    fun feed(pcm16le: ByteArray) {
        val n = pcm16le.size / 2
        val frame = FloatArray(n)
        var energy = 0f
        for (i in 0 until n) {
            val s = (pcm16le[2 * i].toInt() and 0xFF) or (pcm16le[2 * i + 1].toInt() shl 8)
            val v = s.toShort() / 32768f
            frame[i] = v
            energy += abs(v)
        }
        energy /= max(1, n)
        if (gated) {
            if (inSpeech) reset()
            return
        }

        if (!inSpeech) {
            noiseFloor = 0.97f * noiseFloor + 0.03f * energy
            preRoll.addLast(frame)
            while (preRoll.size > preRollFrames) preRoll.removeFirst()
            if (energy > max(0.012f, noiseFloor * 3.5f)) {
                inSpeech = true
                silentRun = 0
                speechFrames = 1
                current.clear()
                current.addAll(preRoll)
            }
            return
        }

        current.add(frame)
        val loud = energy > max(0.008f, noiseFloor * 2f)
        if (loud) {
            speechFrames++
            silentRun = 0
        } else {
            silentRun++
        }
        if (silentRun >= silenceFramesToEnd || current.size >= maxUtteranceFrames) finish()
    }

    private fun finish() {
        val enough = speechFrames >= minSpeechFrames
        val frames = current.toList()
        reset()
        if (!enough) return
        val out = FloatArray(frames.size * frameSamples)
        var o = 0
        for (f in frames) {
            System.arraycopy(f, 0, out, o, minOf(f.size, frameSamples))
            o += frameSamples
        }
        onUtterance(out)
    }
}
