package com.dharani.dharani_mobile

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import android.content.Context
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Whisper-Small speech recognition on the Hexagon NPU (precompiled QNN context binaries run through
 * ONNX Runtime's QNN execution provider). Encoder: 30 s log-mel -> cross-attention caches.
 * Decoder: one token per step with sliding self-attention caches.
 */
class WhisperNpu private constructor(
    private val env: OrtEnvironment,
    private val encoder: OrtSession,
    private val decoder: OrtSession,
    private val idToToken: Array<String?>,
    private val specialIds: Map<String, Int>,
) : AutoCloseable {

    data class Result(
        val text: String,
        val tokens: Int,
        val melMs: Long,
        val encoderMs: Long,
        val decodeMs: Long,
    )

    companion object {
        private const val LAYERS = 12
        private const val CACHE_LEN = 199
        private const val EOT = 50257
        private const val FIRST_SPECIAL = 50258
        private const val VOCAB = 51865

        /** Finds the directory holding encoder.onnx below `root`. */
        fun findModelDir(root: File): File? =
            root.walkTopDown().firstOrNull { it.isFile && it.name == "encoder.onnx" }?.parentFile

        fun load(context: Context, modelRoot: File, tokenizerFile: File): WhisperNpu {
            val dir = findModelDir(modelRoot) ?: throw IllegalStateException("encoder.onnx not found under ${modelRoot.path}")
            AiRuntime.prepareEnvironment(context)
            val env = OrtEnvironment.getEnvironment()
            val encoder = AiRuntime.newSession(env, File(dir, "encoder.onnx").path)
            val decoder = AiRuntime.newSession(env, File(dir, "decoder.onnx").path)

            val json = JSONObject(tokenizerFile.readText())
            val ids = arrayOfNulls<String>(VOCAB)
            val vocab = json.getJSONObject("model").getJSONObject("vocab")
            for (k in vocab.keys()) {
                val id = vocab.getInt(k)
                if (id < VOCAB) ids[id] = k
            }
            val added = json.getJSONArray("added_tokens")
            val special = HashMap<String, Int>()
            for (i in 0 until added.length()) {
                val a = added.getJSONObject(i)
                special[a.getString("content")] = a.getInt("id")
                if (a.getInt("id") < VOCAB) ids[a.getInt("id")] = a.getString("content")
            }
            return WhisperNpu(env, encoder, decoder, ids, special)
        }

        // ---- fp16 helpers ----
        fun floatToHalf(f: Float): Short {
            val bits = java.lang.Float.floatToIntBits(f)
            val sign = (bits ushr 16) and 0x8000
            var exp = ((bits ushr 23) and 0xFF) - 127 + 15
            var mant = bits and 0x7FFFFF
            if (exp <= 0) {
                if (exp < -10) return sign.toShort()
                mant = (mant or 0x800000) shr (1 - exp)
                return (sign or ((mant + 0x1000) shr 13)).toShort()
            }
            if (exp >= 31) return (sign or 0x7C00).toShort()
            return (sign or (exp shl 10) or ((mant + 0x1000) shr 13)).toShort()
        }

        fun halfToFloat(h: Short): Float {
            val x = h.toInt() and 0xFFFF
            val sign = (x and 0x8000) shl 16
            val exp = (x shr 10) and 0x1F
            val mant = x and 0x3FF
            val bits = when {
                exp == 0 -> if (mant == 0) sign else {
                    var e = -1
                    var m = mant
                    while (m and 0x400 == 0) { m = m shl 1; e-- }
                    sign or ((e + 127 - 14 + 1) shl 23) or ((m and 0x3FF) shl 13)
                }
                exp == 31 -> sign or 0x7F800000 or (mant shl 13)
                else -> sign or ((exp - 15 + 127) shl 23) or (mant shl 13)
            }
            return java.lang.Float.intBitsToFloat(bits)
        }

        // GPT-2 byte-level BPE: printable unicode stand-ins back to raw bytes.
        private val unicodeToByte: Map<Char, Int> by lazy {
            val bs = ArrayList<Int>()
            bs.addAll(33..126); bs.addAll(161..172); bs.addAll(174..255)
            val cs = ArrayList<Int>(bs)
            var n = 0
            for (b in 0 until 256) if (b !in bs) { bs.add(b); cs.add(256 + n); n++ }
            HashMap<Char, Int>().also { m -> for (i in bs.indices) m[cs[i].toChar()] = bs[i] }
        }
    }

    private fun halfBuffer(count: Int): ByteBuffer = ByteBuffer.allocateDirect(count * 2).order(ByteOrder.nativeOrder())

    private fun tokenText(ids: List<Int>): String {
        val out = ByteArrayOutputStream()
        for (id in ids) {
            val t = idToToken.getOrNull(id) ?: continue
            if (id >= FIRST_SPECIAL) continue
            for (c in t) out.write(unicodeToByte[c] ?: c.code and 0xFF)
        }
        return out.toString(Charsets.UTF_8.name()).trim()
    }

    fun transcribe(pcm: FloatArray, language: String, translateToEnglish: Boolean): Result {
        val t0 = System.nanoTime()
        // Phone mics in a cab are quiet and uneven; Whisper was trained on level-normalised audio.
        // Scale so the loudest samples sit near 0.9 (gain capped so silence is not blown up into noise).
        var peak = 0f
        for (v in pcm) { val a = kotlin.math.abs(v); if (a > peak) peak = a }
        val normalised = if (peak > 0.005f) {
            val g = minOf(0.9f / peak, 12f)
            if (g > 1.2f) FloatArray(pcm.size) { pcm[it] * g } else pcm
        } else pcm
        val mel = MelSpectrogram.compute(normalised)
        val t1 = System.nanoTime()

        val feats = halfBuffer(mel.size)
        for (v in mel) feats.putShort(floatToHalf(v))
        feats.rewind()
        val featTensor = OnnxTensor.createTensor(env, feats, longArrayOf(1, 80, 3000), OnnxJavaType.FLOAT16)
        val enc = encoder.run(mapOf("input_features" to featTensor))
        featTensor.close()
        val t2 = System.nanoTime()

        val cross = HashMap<String, OnnxTensor>()
        for (i in 0 until LAYERS) {
            cross["k_cache_cross_$i"] = enc.get("k_cache_cross_$i").get() as OnnxTensor
            cross["v_cache_cross_$i"] = enc.get("v_cache_cross_$i").get() as OnnxTensor
        }

        val langId = specialIds["<|$language|>"] ?: throw IllegalArgumentException("Whisper does not support language '$language'")
        val prompt = listOf(
            specialIds.getValue("<|startoftranscript|>"),
            langId,
            specialIds.getValue(if (translateToEnglish) "<|translate|>" else "<|transcribe|>"),
            specialIds.getValue("<|notimestamps|>"),
        )

        // Self-attention caches start zeroed; the decoder returns them shifted by one each step.
        val zeroTensors = ArrayList<OnnxTensor>()
        var self = HashMap<String, OnnxTensor>()
        for (i in 0 until LAYERS) {
            val k = OnnxTensor.createTensor(env, halfBuffer(12 * 64 * CACHE_LEN), longArrayOf(12, 1, 64, CACHE_LEN.toLong()), OnnxJavaType.FLOAT16)
            val v = OnnxTensor.createTensor(env, halfBuffer(12 * CACHE_LEN * 64), longArrayOf(12, 1, CACHE_LEN.toLong(), 64), OnnxJavaType.FLOAT16)
            zeroTensors.add(k); zeroTensors.add(v)
            self["k_cache_self_${i}_in"] = k
            self["v_cache_self_${i}_in"] = v
        }

        val mask = FloatArray(200) { -100f }
        mask[199] = 0f
        val generated = ArrayList<Int>()
        var prev: OrtSession.Result? = null
        var steps = 0
        try {
            for (n in 0 until CACHE_LEN) {
                val tokenIn = if (n < prompt.size) prompt[n] else generated.last()
                val ids = OnnxTensor.createTensor(env, java.nio.IntBuffer.wrap(intArrayOf(tokenIn)), longArrayOf(1, 1))
                val pos = OnnxTensor.createTensor(env, java.nio.IntBuffer.wrap(intArrayOf(n)), longArrayOf(1))
                val mb = halfBuffer(200)
                for (m in mask) mb.putShort(floatToHalf(m))
                mb.rewind()
                val maskTensor = OnnxTensor.createTensor(env, mb, longArrayOf(1, 1, 1, 200), OnnxJavaType.FLOAT16)

                val inputs = HashMap<String, OnnxTensor>()
                inputs["input_ids"] = ids
                inputs["attention_mask"] = maskTensor
                inputs["position_ids"] = pos
                inputs.putAll(self)
                inputs.putAll(cross)
                val res = decoder.run(inputs)
                ids.close(); pos.close(); maskTensor.close()
                steps++

                val next = HashMap<String, OnnxTensor>()
                for (i in 0 until LAYERS) {
                    next["k_cache_self_${i}_in"] = res.get("k_cache_self_${i}_out").get() as OnnxTensor
                    next["v_cache_self_${i}_in"] = res.get("v_cache_self_${i}_out").get() as OnnxTensor
                }
                prev?.close()
                prev = res
                self = next
                mask[CACHE_LEN - n - 1 + 0] = 0f // the entry just written is now visible to later steps

                if (n >= prompt.size - 1) {
                    val logits = (res.get("logits").get() as OnnxTensor).byteBuffer.order(ByteOrder.nativeOrder()).asShortBuffer()
                    var best = EOT
                    var bestV = -Float.MAX_VALUE
                    val first = generated.isEmpty()
                    for (id in 0 until VOCAB) {
                        if (id >= FIRST_SPECIAL) continue // no timestamps / specials while generating
                        if (first && id == EOT) continue
                        val v = halfToFloat(logits.get(id))
                        if (v > bestV) { bestV = v; best = id }
                    }
                    val eot = halfToFloat(logits.get(EOT))
                    if (!first && eot >= bestV) best = EOT
                    if (best == EOT) break
                    generated.add(best)
                    if (generated.size > 8 && generated.takeLast(8).toSet().size == 1) break // stuck repeating
                    // Greedy decoding can loop on a phrase ("... पहुंचाइए पहुंचाइए पहुंचाइए"): stop and drop the loop.
                    val g = generated
                    if (g.size >= 12) {
                        val a = g.takeLast(4)
                        if (g.subList(g.size - 8, g.size - 4) == a && g.subList(g.size - 12, g.size - 8) == a) {
                            repeat(8) { g.removeAt(g.size - 1) }
                            break
                        }
                    }
                }
            }
        } finally {
            prev?.close()
            for (t in zeroTensors) t.close()
            enc.close()
        }
        val t3 = System.nanoTime()
        return Result(tokenText(generated), generated.size, (t1 - t0) / 1_000_000, (t2 - t1) / 1_000_000, (t3 - t2) / 1_000_000)
    }

    override fun close() {
        encoder.close()
        decoder.close()
    }
}
