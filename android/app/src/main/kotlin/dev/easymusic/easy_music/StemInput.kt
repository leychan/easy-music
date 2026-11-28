package dev.easymusic.easy_music

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import java.io.BufferedOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

internal const val STEM_SAMPLE_RATE = 44100

internal class StemFailure(val code: String, message: String) : Exception(message)

/** 把 Android 能解码的单声道或立体声文件转为模型需要的 44.1 kHz 立体声。 */
internal fun decodeStemInput(source: File, output: File, check: () -> Unit): IntRange {
    val extractor = MediaExtractor()
    try {
        extractor.setDataSource(source.path)
        val audio = (0 until extractor.trackCount).firstOrNull {
            extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true
        } ?: throw StemFailure("format", "文件中没有可解码的音轨。")
        extractor.selectTrack(audio)
        val format = extractor.getTrackFormat(audio)
        val mime = checkNotNull(format.getString(MediaFormat.KEY_MIME))
        val rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val delay = format.getInteger(MediaFormat.KEY_ENCODER_DELAY, 0)
        val padding = format.getInteger(MediaFormat.KEY_ENCODER_PADDING, 0)
        BufferedOutputStream(output.outputStream(), 65536).use { stream ->
            val pcm = StemPcmWriter(stream)
            if (mime == MediaFormat.MIMETYPE_AUDIO_RAW) {
                val packetSize = maxOf(256 * 1024, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 0))
                val packet = ByteBuffer.allocate(packetSize)
                while (true) {
                    check()
                    packet.clear()
                    val size = extractor.readSampleData(packet, 0)
                    if (size < 0) break
                    packet.limit(size)
                    pcm.write(packet, format)
                    extractor.advance()
                }
            } else {
                val decoder = MediaCodec.createDecoderByType(mime)
                try {
                    // 和 Media3 一样在 PCM 端处理 gapless 标记，避免解码器重复裁剪。
                    format.setInteger(MediaFormat.KEY_ENCODER_DELAY, 0)
                    format.setInteger(MediaFormat.KEY_ENCODER_PADDING, 0)
                    decoder.configure(format, null, null, 0)
                    decoder.start()
                    decodePackets(extractor, decoder, pcm, format, check)
                } finally {
                    decoder.release()
                }
            }
            pcm.finish()
            val start = (delay.toLong() * STEM_SAMPLE_RATE / rate).toInt().coerceIn(0, pcm.frames)
            val end = (pcm.frames - padding.toLong() * STEM_SAMPLE_RATE / rate).toInt()
                .coerceIn(start, pcm.frames)
            if (start == end) throw StemFailure("format", "文件中没有可分离的声音。")
            return start until end
        }
    } finally {
        extractor.release()
    }
}

private fun MediaFormat.getInteger(key: String, fallback: Int): Int =
    if (containsKey(key)) getInteger(key) else fallback

private fun decodePackets(
    extractor: MediaExtractor,
    decoder: MediaCodec,
    pcm: StemPcmWriter,
    format: MediaFormat,
    check: () -> Unit,
) {
    val info = MediaCodec.BufferInfo()
    var inputEnded = false
    var decodedFormat = format
    var lastActivity = android.os.SystemClock.elapsedRealtime()
    while (true) {
        check()
        if (!inputEnded) {
            val index = decoder.dequeueInputBuffer(5000)
            if (index >= 0) {
                val buffer = checkNotNull(decoder.getInputBuffer(index))
                buffer.clear()
                val size = extractor.readSampleData(buffer, 0)
                inputEnded = size < 0
                val timestamp = if (inputEnded) 0 else extractor.sampleTime
                val flags = if (inputEnded) MediaCodec.BUFFER_FLAG_END_OF_STREAM else 0
                decoder.queueInputBuffer(index, 0, size.coerceAtLeast(0), timestamp, flags)
                if (!inputEnded) extractor.advance()
                lastActivity = android.os.SystemClock.elapsedRealtime()
            }
        }
        when (val index = decoder.dequeueOutputBuffer(info, 5000)) {
            MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> decodedFormat = decoder.outputFormat
            MediaCodec.INFO_TRY_AGAIN_LATER -> {
                if (android.os.SystemClock.elapsedRealtime() - lastActivity > 15000) {
                    throw StemFailure("format", "解码歌曲超时。")
                }
            }
            else -> if (index >= 0) {
                lastActivity = android.os.SystemClock.elapsedRealtime()
                try {
                    if (info.size > 0 && info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0) {
                        val buffer = checkNotNull(decoder.getOutputBuffer(index))
                        buffer.position(info.offset)
                        buffer.limit(info.offset + info.size)
                        pcm.write(buffer, decodedFormat)
                    }
                } finally {
                    decoder.releaseOutputBuffer(index, false)
                }
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) return
            }
        }
    }
}

private class StemPcmWriter(private val output: BufferedOutputStream) {
    var frames = 0
        private set
    private var inputFrames = 0
    private var rate = 0
    private var previousLeft = 0f
    private var previousRight = 0f
    private val bytes = ByteBuffer.allocate(64 * 1024).order(ByteOrder.LITTLE_ENDIAN)

    fun write(buffer: ByteBuffer, format: MediaFormat) {
        val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
        val encoding = format.getInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)
        val inputRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        if (channels !in 1..2 || inputRate <= 0 || (rate != 0 && rate != inputRate)) {
            throw StemFailure("format", "分轨需要采样率固定的单声道或立体声音频。")
        }
        rate = inputRate
        val sampleBytes = when (encoding) {
            AudioFormat.ENCODING_PCM_8BIT -> 1
            AudioFormat.ENCODING_PCM_16BIT -> 2
            AudioFormat.ENCODING_PCM_24BIT_PACKED -> 3
            AudioFormat.ENCODING_PCM_FLOAT, AudioFormat.ENCODING_PCM_32BIT -> 4
            else -> throw StemFailure("format", "分轨暂不支持这首歌的采样格式。")
        }
        buffer.order(ByteOrder.LITTLE_ENDIAN)
        while (buffer.remaining() >= channels * sampleBytes) {
            val left = sample(buffer, encoding)
            val right = if (channels == 2) sample(buffer, encoding) else left
            // 用整数帧计数定位插值点，跨解码缓冲也能连续重采样。
            val current = inputFrames.toLong() * STEM_SAMPLE_RATE
            while (frames.toLong() * rate <= current) {
                val fraction = 1f - (current - frames.toLong() * rate).toFloat() / STEM_SAMPLE_RATE
                val outLeft = if (inputFrames == 0) left else previousLeft + (left - previousLeft) * fraction
                val outRight = if (inputFrames == 0) right else previousRight + (right - previousRight) * fraction
                writeFrame(outLeft, outRight)
            }
            previousLeft = left
            previousRight = right
            inputFrames++
        }
    }

    fun finish() {
        while (frames.toLong() * rate < inputFrames.toLong() * STEM_SAMPLE_RATE) {
            writeFrame(previousLeft, previousRight)
        }
        flush()
    }

    private fun writeFrame(left: Float, right: Float) {
        if (frames >= MAX_STEM_BYTES / 8) {
            throw StemFailure("length", "这首歌过长，超出了分轨缓存上限。")
        }
        bytes.putShort(pcm16(left))
        bytes.putShort(pcm16(right))
        frames++
        if (!bytes.hasRemaining()) flush()
    }

    private fun flush() {
        output.write(bytes.array(), 0, bytes.position())
        bytes.clear()
    }

    private fun sample(buffer: ByteBuffer, encoding: Int): Float = when (encoding) {
        AudioFormat.ENCODING_PCM_8BIT -> ((buffer.get().toInt() and 255) - 128) / 128f
        AudioFormat.ENCODING_PCM_16BIT -> buffer.short / 32768f
        AudioFormat.ENCODING_PCM_24BIT_PACKED -> {
            val low = buffer.get().toInt() and 255
            val middle = buffer.get().toInt() and 255
            val high = buffer.get().toInt()
            (low or (middle shl 8) or (high shl 16)) / 8388608f
        }
        AudioFormat.ENCODING_PCM_32BIT -> buffer.int / 2147483648f
        else -> buffer.float
    }
}

internal fun pcm16(value: Float): Short =
    if (value.isFinite()) (value.coerceIn(-1f, 1f) * 32768f).roundToInt()
        .coerceIn(-32768, 32767).toShort() else 0
