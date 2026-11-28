package dev.easymusic.easy_music

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.BufferedOutputStream
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

private const val FFT_SIZE = 4096
private const val HOP = 1024
private const val BINS = 1024
private const val SIBILANCE_START = 7000 * FFT_SIZE / STEM_SAMPLE_RATE
private const val EXTENDED_BINS = 16000 * FFT_SIZE / STEM_SAMPLE_RATE + 1
private const val WINDOWS = 512
private const val CONTEXT = 16
private const val CHUNK_FRAMES = (WINDOWS - CONTEXT * 2) * HOP
private const val CHUNK_PADDING = CONTEXT * HOP + FFT_SIZE / 2
private const val CROSSFADE = 8 * HOP
private const val SPECTRUM_FRAMES = (WINDOWS - 1) * HOP + FFT_SIZE
private const val SPECTRUM_SIZE = 2 * WINDOWS * BINS
private const val PHASE_SIZE = 2 * WINDOWS * EXTENDED_BINS
internal const val STEM_HEADROOM = 0.5f

internal fun writeStems(
    vocalsModel: File,
    accompanimentModel: File,
    inputFile: File,
    frames: IntRange,
    output: File,
    job: StemJob,
    progress: (String, Double?) -> Unit,
) {
    val frameCount = frames.last - frames.first + 1
    progress("separating", 0.0)
    val environment = OrtEnvironment.getEnvironment()
    OrtSession.SessionOptions().use { options ->
        options.setIntraOpNumThreads((Runtime.getRuntime().availableProcessors() / 2).coerceIn(1, 3))
        options.addConfigEntry("session.intra_op.allow_spinning", "0")
        // 两个模型交替推理，不让两个内存池各自保留最大临时张量。
        options.setCPUArenaAllocator(false)
        environment.createSession(vocalsModel.path, options).use { vocals ->
            job.check()
            environment.createSession(accompanimentModel.path, options).use { accompaniment ->
                val transform = StemSpectrum()
                val shape = longArrayOf(2, 1, WINDOWS.toLong(), BINS.toLong())
                OnnxTensor.createTensor(environment, transform.magnitudes, shape).use { input ->
                    OnnxTensor.createTensor(environment, transform.vocals, shape).use { voice ->
                        OnnxTensor.createTensor(environment, transform.accompaniment, shape).use { music ->
                            val inputs = mapOf(vocals.inputNames.single() to input)
                            val voiceOutputs = mapOf(vocals.outputNames.single() to voice)
                            val musicOutputs = mapOf(accompaniment.outputNames.single() to music)
                            RandomAccessFile(inputFile, "r").use { pcm ->
                                StemWaveWriter(output, frameCount).use { wave ->
                                    var cursor = 0
                                    while (cursor < frameCount) {
                                        job.check()
                                        transform.read(pcm, frames, cursor)
                                        transform.analyze()
                                        job.run(vocals, inputs, voiceOutputs)
                                        job.run(accompaniment, inputs, musicOutputs)
                                        val count = minOf(CHUNK_FRAMES, frameCount - cursor)
                                        val last = cursor + count == frameCount
                                        val written = if (last) count else count - CROSSFADE
                                        transform.synthesize(count, written, cursor == 0, wave)
                                        cursor += written
                                        progress("separating", cursor.toDouble() / frameCount)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun nativeFloats(size: Int): FloatBuffer =
    ByteBuffer.allocateDirect(size * Float.SIZE_BYTES).order(ByteOrder.nativeOrder()).asFloatBuffer()

private class StemSpectrum {
    val magnitudes = nativeFloats(SPECTRUM_SIZE)
    val vocals = nativeFloats(SPECTRUM_SIZE)
    val accompaniment = nativeFloats(SPECTRUM_SIZE)
    private val phaseReal = FloatArray(PHASE_SIZE)
    private val phaseImaginary = FloatArray(PHASE_SIZE)
    private val real = FloatArray(FFT_SIZE)
    private val imaginary = FloatArray(FFT_SIZE)
    private val fft = StemFft()
    private val window = FloatArray(FFT_SIZE) { (0.5 - 0.5 * cos(it * 2 * PI / FFT_SIZE)).toFloat() }
    private val pcm = ByteArray(SPECTRUM_FRAMES * 4)
    private val samples = ByteBuffer.wrap(pcm).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
    private val separated = Array(2) { FloatArray(SPECTRUM_FRAMES) }
    private val tail = Array(2) { FloatArray(CROSSFADE) }

    fun read(input: RandomAccessFile, frames: IntRange, cursor: Int) {
        val start = cursor - CHUNK_PADDING
        val actualStart = maxOf(0, start)
        val actualEnd = minOf(frames.last - frames.first + 1, start + SPECTRUM_FRAMES)
        val firstByte = (actualStart - start) * 4
        val bytes = (actualEnd - actualStart) * 4
        pcm.fill(0, 0, firstByte)
        pcm.fill(0, firstByte + bytes)
        input.seek((frames.first + actualStart.toLong()) * 4)
        input.readFully(pcm, firstByte, bytes)
    }

    fun analyze() {
        // 模型输入为左右声道的幅度谱，保留相位供逆变换使用。
        for (channel in 0..1) {
            for (frame in 0 until WINDOWS) {
                val start = frame * HOP
                for (i in 0 until FFT_SIZE) {
                    real[i] = samples.get((start + i) * 2 + channel) / 32768f * window[i]
                }
                imaginary.fill(0f)
                fft.transform(real, imaginary, inverse = false)
                val position = channel * WINDOWS + frame
                val offset = position * BINS
                val phaseOffset = position * EXTENDED_BINS
                for (bin in 0 until EXTENDED_BINS) {
                    val r = real[bin]
                    val i = imaginary[bin]
                    phaseReal[phaseOffset + bin] = r
                    phaseImaginary[phaseOffset + bin] = i
                    if (bin < BINS) magnitudes.put(offset + bin, sqrt(r * r + i * i))
                }
            }
        }
    }

    fun synthesize(count: Int, written: Int, firstChunk: Boolean, wave: StemWaveWriter) {
        val coreEnd = CHUNK_PADDING + count
        for (channel in 0..1) {
            val voice = separated[channel]
            voice.fill(0f, CHUNK_PADDING, coreEnd)
            var sibilance = 0f
            for (frame in 0 until WINDOWS) {
                val start = frame * HOP
                if (start + FFT_SIZE <= CHUNK_PADDING) continue
                if (start >= coreEnd) break
                real.fill(0f)
                imaginary.fill(0f)
                val position = channel * WINDOWS + frame
                val offset = position * BINS
                val phaseOffset = position * EXTENDED_BINS
                val confidence = sibilanceConfidence(offset)
                sibilance += (confidence - sibilance) * if (confidence > sibilance) 0.8f else 0.55f
                for (bin in 0 until EXTENDED_BINS) {
                    val baseMask = if (bin < BINS) vocalMask(offset + bin) else 0f
                    val ratio = stemSibilanceMask(baseMask, bin, sibilance)
                    val r = phaseReal[phaseOffset + bin] * ratio
                    val i = phaseImaginary[phaseOffset + bin] * ratio
                    real[bin] = r
                    imaginary[bin] = i
                    if (bin > 0) {
                        real[FFT_SIZE - bin] = r
                        imaginary[FFT_SIZE - bin] = -i
                    }
                }
                fft.transform(real, imaginary, inverse = true)
                val first = maxOf(CHUNK_PADDING - start, 0)
                val last = minOf(FFT_SIZE, coreEnd - start)
                for (i in first until last) voice[start + i] += real[i] * window[i]
            }
        }
        // 只保留带有完整上下文的中段。周期 Hann 窗和 75% 重叠的平方窗恒定为 1.5。
        for (frame in 0 until written) {
            val i = CHUNK_PADDING + frame
            var left = separated[0][i] / 1.5f
            var right = separated[1][i] / 1.5f
            if (!firstChunk && frame < CROSSFADE) {
                // 相邻推理窗口的估计略有变化，交叉淡化避免分段边界出现爆音。
                val gain = frame.toFloat() / (CROSSFADE - 1)
                left = tail[0][frame] * (1f - gain) + left * gain
                right = tail[1][frame] * (1f - gain) + right * gain
            }
            // 从原声里扣除人声，包括识别出的高频齿音，剩下的作为伴奏。
            wave.write(left, right, samples.get(i * 2) / 32768f - left, samples.get(i * 2 + 1) / 32768f - right)
        }
        for (channel in 0..1) {
            for (frame in written until count) {
                tail[channel][frame - written] = separated[channel][CHUNK_PADDING + frame] / 1.5f
            }
        }
    }

    private fun vocalMask(index: Int): Float {
        val vocal = vocals.get(index)
        val music = accompaniment.get(index)
        val power = vocal * vocal
        return power / (power + music * music + 1e-10f)
    }

    private fun sibilanceConfidence(offset: Int): Float {
        var mixPower = 0f
        var vocalPower = 0f
        for (bin in SIBILANCE_START until BINS) {
            val magnitude = magnitudes.get(offset + bin)
            val energy = magnitude * magnitude
            mixPower += energy
            vocalPower += energy * vocalMask(offset + bin)
        }
        return ((vocalPower / (mixPower + 1e-6f) - 0.62f) / 0.28f).coerceIn(0f, 1f)
    }
}

/** 用模型高频端的人声把握补偿齿音；频带越高越收敛，保留不确定的镲片声。 */
internal fun stemSibilanceMask(base: Float, bin: Int, confidence: Float): Float {
    if (confidence <= 0f || bin < SIBILANCE_START) return base
    if (bin < BINS) {
        val blend = (bin - SIBILANCE_START).toFloat() / (BINS - SIBILANCE_START)
        return base + (1f - base) * base * blend * confidence * 0.3f
    }
    val taper = (EXTENDED_BINS - 1 - bin).toFloat() / (EXTENDED_BINS - BINS)
    return 0.7f * confidence * taper.coerceIn(0f, 1f)
}

/** 固定窗口的原地 FFT，重用位倒序和系数表，避免每帧分配内存。 */
private class StemFft {
    private val reversed = IntArray(FFT_SIZE) { Integer.reverse(it) ushr 20 }
    private val cosines = FloatArray(FFT_SIZE / 2) { cos(it * 2 * PI / FFT_SIZE).toFloat() }
    private val sines = FloatArray(FFT_SIZE / 2) { sin(it * 2 * PI / FFT_SIZE).toFloat() }

    fun transform(real: FloatArray, imaginary: FloatArray, inverse: Boolean) {
        for (i in 0 until FFT_SIZE) {
            val j = reversed[i]
            if (j <= i) continue
            val r = real[i]
            val im = imaginary[i]
            real[i] = real[j]
            imaginary[i] = imaginary[j]
            real[j] = r
            imaginary[j] = im
        }
        var size = 2
        while (size <= FFT_SIZE) {
            val half = size / 2
            val stride = FFT_SIZE / size
            var start = 0
            while (start < FFT_SIZE) {
                for (i in 0 until half) {
                    val index = i * stride
                    val cos = cosines[index]
                    val sin = if (inverse) sines[index] else -sines[index]
                    val first = start + i
                    val second = first + half
                    val r = real[second] * cos - imaginary[second] * sin
                    val im = real[second] * sin + imaginary[second] * cos
                    real[second] = real[first] - r
                    imaginary[second] = imaginary[first] - im
                    real[first] += r
                    imaginary[first] += im
                }
                start += size
            }
            size *= 2
        }
        if (inverse) {
            for (i in 0 until FFT_SIZE) real[i] /= FFT_SIZE.toFloat()
        }
    }
}

private class StemWaveWriter(file: File, frames: Int) : AutoCloseable {
    private val stream = BufferedOutputStream(file.outputStream())
    private val output = ByteBuffer.allocate(64 * 1024).order(ByteOrder.LITTLE_ENDIAN)

    init {
        // 「人声 L/R、伴奏 L/R」共享 WAV 时间轴，Media3 输出前再合成两声道。
        val size = frames * 8
        output.put("RIFF".toByteArray()).putInt(size + 36).put("WAVEfmt ".toByteArray())
        output.putInt(16).putShort(1).putShort(4).putInt(STEM_SAMPLE_RATE).putInt(STEM_SAMPLE_RATE * 8)
        output.putShort(8).putShort(16).put("data".toByteArray()).putInt(size)
        flush()
    }

    fun write(voiceLeft: Float, voiceRight: Float, musicLeft: Float, musicRight: Float) {
        output.putShort(pcm16(voiceLeft * STEM_HEADROOM))
        output.putShort(pcm16(voiceRight * STEM_HEADROOM))
        output.putShort(pcm16(musicLeft * STEM_HEADROOM))
        output.putShort(pcm16(musicRight * STEM_HEADROOM))
        if (!output.hasRemaining()) flush()
    }

    private fun flush() {
        stream.write(output.array(), 0, output.position())
        output.clear()
    }

    override fun close() {
        stream.use { flush() }
    }
}
