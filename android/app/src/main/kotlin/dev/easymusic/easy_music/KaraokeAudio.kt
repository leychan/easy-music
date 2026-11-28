package dev.easymusic.easy_music

import android.annotation.SuppressLint
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Process
import android.os.SystemClock
import androidx.annotation.OptIn
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.audio.AudioOutput
import androidx.media3.exoplayer.audio.ForwardingAudioOutput
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.abs
import kotlin.math.roundToInt

private const val BLOCK_FRAMES = 256
private const val CAPTURE_CAPACITY = 8192
private const val CAPTURE_MAX_LAG = STEM_SAMPLE_RATE / 40
private const val CAPTURE_TARGET_LAG = STEM_SAMPLE_RATE * 15 / 1000
private const val MAX_MICROPHONE_GAIN = 4f
internal const val DEFAULT_MICROPHONE_GAIN = 0.5f

internal data class KaraokeFrameTime(val frame: Long, val nanoTime: Long) {
    fun frameAt(time: Long): Long =
        frame + ((time - nanoTime).toDouble() * STEM_SAMPLE_RATE / 1_000_000_000).toLong()

    fun timeAt(position: Long): Long =
        nanoTime + (position - frame) * 1_000_000_000L / STEM_SAMPLE_RATE
}

/** 麦克风数据只在内存里保留，用于耳返。 */
internal class KaraokeCapture(private val onFailure: (KaraokeCapture) -> Unit) {
    private val running = AtomicBoolean(true)
    private val pcm = ShortArray(CAPTURE_CAPACITY)
    @Volatile private var written = 0L
    @Volatile private var inputClock: KaraokeFrameTime? = null
    private val captureFloor = AtomicReference(KaraokeFrameTime(0, Long.MIN_VALUE))
    @Volatile private var inputLevel = 0f
    @Volatile private var route = "麦克风"
    @Volatile private var silenced = false
    @Volatile private var reachedOutput = false
    @Volatile private var bluetoothOutput = false
    private var consumed = 0L

    fun start(executor: Executor) {
        executor.execute(::capture)
    }

    fun stop() {
        running.set(false)
    }

    fun discardBefore(time: Long) {
        captureFloor.updateAndGet { if (time > it.nanoTime) KaraokeFrameTime(written, time) else it }
    }

    fun synchronizationTime(): Long = captureFloor.get().nanoTime

    fun reportOutput(bluetooth: Boolean) {
        reachedOutput = true
        bluetoothOutput = bluetooth
    }

    fun status(): Map<String, Any> = mapOf(
        "level" to inputLevel.toDouble(),
        "route" to route,
        "bluetoothOutput" to bluetoothOutput,
        "state" to when {
            silenced -> "silenced"
            written == 0L -> "opening"
            !reachedOutput -> "output"
            else -> "active"
        },
    )

    /** 同一个单调时钟限制拾音窗口。已经过去的音频只取最近可用帧，禁止在跳转后重放旧拾音。 */
    fun read(target: ShortArray, frames: Int, playoutNanos: Long) {
        val end = written
        val clock = inputClock
        val cutoff = captureFloor.get()
        val firstValidFrame = if (clock == null || cutoff.nanoTime == Long.MIN_VALUE) cutoff.frame
            else maxOf(cutoff.frame, clock.frameAt(cutoff.nanoTime))
        val aligned = clock?.frameAt(playoutNanos)
        // 保留约 15 毫秒拾音余量供连续写入，避免系统一口气要几块时反复跳帧。
        val alignedStart = aligned?.let { minOf(it - CAPTURE_TARGET_LAG, end - frames) } ?: 0L
        val availableAtPlayout = aligned?.let { minOf(end, it + frames) } ?: end
        consumed = maxOf(consumed, firstValidFrame, end - CAPTURE_MAX_LAG, alignedStart)
        val timedCount = (availableAtPlayout - consumed).coerceIn(0L, frames.toLong())
        // 蓝牙改路由时设备时间戳可能落后；时间窗口为空时继续用当前段有效的拾音。
        val count = (if (timedCount == 0L) (end - consumed).coerceIn(0L, frames.toLong())
            else timedCount).toInt()
        for (index in 0 until count) {
            target[index] = pcm[((consumed + index) and (CAPTURE_CAPACITY - 1).toLong()).toInt()]
        }
        target.fill(0, count, frames)
        consumed += count
    }

    @SuppressLint("MissingPermission") // StemPlugin 在允许启动前检查录音授权。
    private fun capture() {
        var recorder: AudioRecord? = null
        var effects = emptyList<AudioEffect>()
        try {
            if (!running.get()) return
            Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
            val size = AudioRecord.getMinBufferSize(
                STEM_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            )
            if (size <= 0) throw IllegalStateException("Unsupported microphone format")
            // 部分设备能打开低延迟专用输入，但耳返会收到很小的信号。优先用普通麦克风通路。
            recorder = startRecord(MediaRecorder.AudioSource.MIC, size)
                ?: startRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, size)
                ?: throw IllegalStateException("Cannot open microphone")
            val audioSession = recorder.audioSessionId
            effects = listOfNotNull(
                enableCaptureEffect { if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(audioSession) else null },
                enableCaptureEffect { if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(audioSession) else null },
            )
            val block = ShortArray(BLOCK_FRAMES)
            val timestamp = AudioTimestamp()
            var nextClockCheck = 0L
            var nextRouteCheck = 0L
            while (running.get()) {
                val count = recorder.read(block, 0, block.size, AudioRecord.READ_BLOCKING)
                if (count < 0) throw IllegalStateException("Microphone read failed")
                if (count == 0) {
                    Thread.sleep(2)
                    continue
                }
                val start = written
                if (start >= nextClockCheck) {
                    val time = System.nanoTime()
                    val hasTimestamp = recorder.getTimestamp(timestamp, AudioTimestamp.TIMEBASE_MONOTONIC) ==
                        AudioRecord.SUCCESS
                    inputClock = if (hasTimestamp &&
                        timestamp.nanoTime in (time - 1_000_000_000L)..(time + 50_000_000L) &&
                        abs(timestamp.framePosition - start - count) <= STEM_SAMPLE_RATE / 2) {
                        KaraokeFrameTime(timestamp.framePosition, timestamp.nanoTime)
                    } else {
                        KaraokeFrameTime(start + count, time)
                    }
                    nextClockCheck = start + STEM_SAMPLE_RATE / 5
                }
                var peak = 0
                for (index in 0 until count) {
                    val sample = block[index]
                    pcm[((start + index) and (CAPTURE_CAPACITY - 1).toLong()).toInt()] = sample
                    peak = maxOf(peak, abs(sample.toInt()))
                }
                inputLevel = maxOf(peak / 32768f, inputLevel * 0.97f)
                if (start >= nextRouteCheck) {
                    route = when (recorder.routedDevice?.type) {
                        AudioDeviceInfo.TYPE_BUILTIN_MIC -> "手机麦克风"
                        AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLE_HEADSET -> "蓝牙耳机麦克风"
                        AudioDeviceInfo.TYPE_WIRED_HEADSET -> "有线耳机麦克风"
                        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> "USB 麦克风"
                        else -> "麦克风"
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        silenced = recorder.activeRecordingConfiguration?.isClientSilenced == true
                    }
                    nextRouteCheck = start + STEM_SAMPLE_RATE / 4
                }
                written = start + count
            }
        } catch (_: Exception) {
            if (running.get()) onFailure(this)
        } finally {
            recorder?.let {
                runCatching { it.stop() }
                effects.forEach { effect -> runCatching { effect.release() } }
                it.release()
            }
        }
    }

    private fun enableCaptureEffect(create: () -> AudioEffect?): AudioEffect? {
        val effect = runCatching(create).getOrNull() ?: return null
        if (runCatching { effect.setEnabled(true) == AudioEffect.SUCCESS }.getOrDefault(false)) {
            return effect
        }
        runCatching { effect.release() }
        return null
    }

    @SuppressLint("MissingPermission")
    private fun startRecord(source: Int, size: Int): AudioRecord? {
        if (!running.get()) return null
        val record = try {
            AudioRecord(
                source, STEM_SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(size, BLOCK_FRAMES * 8),
            )
        } catch (_: IllegalArgumentException) {
            return null
        }
        if (record.state == AudioRecord.STATE_INITIALIZED) {
            try {
                record.startRecording()
                if (record.recordingState == AudioRecord.RECORDSTATE_RECORDING) return record
            } catch (_: IllegalStateException) {
                // 尝试下一种输入配置。
            } catch (error: SecurityException) {
                record.release()
                throw error
            }
        }
        record.release()
        return null
    }
}

@OptIn(UnstableApi::class)
internal class KaraokeAudioOutput(
    delegate: AudioOutput,
    private val capture: () -> KaraokeCapture?,
    private val microphoneGain: () -> Float,
    private val microphoneReverb: () -> Float,
    private val outputBuffer: KaraokeOutputBuffer? = null,
) : ForwardingAudioOutput(delegate) {
    private val microphone = ShortArray(BLOCK_FRAMES)
    private val mixed = ByteBuffer.allocateDirect(BLOCK_FRAMES * 4).order(ByteOrder.LITTLE_ENDIAN)
        .apply { limit(0) }
    private var mixedFrom: KaraokeCapture? = null
    private var mixedAfter = Long.MIN_VALUE
    private val voiceEffect = KaraokeVoiceEffect(STEM_SAMPLE_RATE)
    private var gain = 0f
    private var wet = 0f
    private var submittedFrames = 0L

    override fun write(buffer: ByteBuffer, encodedAccessUnitCount: Int, presentationTimeUs: Long): Boolean {
        outputBuffer?.update(capture() != null)
        while (buffer.hasRemaining()) {
            val live = capture()
            val cutoff = live?.synchronizationTime() ?: Long.MIN_VALUE
            if (live !== mixedFrom || cutoff != mixedAfter) {
                clearMix()
                mixedFrom = live
                mixedAfter = cutoff
            }
            if (live == null) return writePcm(buffer, encodedAccessUnitCount, presentationTimeUs)
            if (!mixed.hasRemaining()) {
                val frames = minOf(BLOCK_FRAMES, buffer.remaining() / 4)
                if (frames == 0) return writePcm(buffer, encodedAccessUnitCount, presentationTimeUs)
                prepareBlock(buffer, live, frames)
            }
            // 一直写到 AudioTrack 接收不下为止。只推进实际写入的字节，剩余留到下一次。
            val before = mixed.position()
            val finished = writePcm(mixed, encodedAccessUnitCount, presentationTimeUs)
            val accepted = mixed.position() - before
            buffer.position(buffer.position() + accepted)
            if (accepted > 0) live.reportOutput(outputBuffer?.bluetooth == true)
            if (!finished) return false
        }
        return true
    }

    private fun writePcm(buffer: ByteBuffer, encodedAccessUnitCount: Int, presentationTimeUs: Long): Boolean {
        val before = buffer.position()
        val finished = super.write(buffer, encodedAccessUnitCount, presentationTimeUs)
        submittedFrames += (buffer.position() - before) / 4
        return finished
    }

    private fun prepareBlock(buffer: ByteBuffer, live: KaraokeCapture, frames: Int) {
        val now = System.nanoTime()
        // 蓝牙等输出可能还有队列。已过去的歌曲帧无法重写，优先将最新拾音送到可写的下一帧。
        val playout = outputBuffer?.playoutTime(submittedFrames, now) ?: now
        live.read(microphone, frames, minOf(now, playout))
        mixed.clear()
        val target = microphoneGain() * MAX_MICROPHONE_GAIN
        val targetWet = microphoneReverb() * 0.6f
        var offset = buffer.position()
        repeat(frames) { frame ->
            gain += (target - gain) * 0.01f
            wet += (targetWet - wet) * 0.01f
            voiceEffect.process(microphone[frame].toFloat())
            val voiceLeft = (voiceEffect.dry + voiceEffect.roomLeft * wet) * gain
            val voiceRight = (voiceEffect.dry + voiceEffect.roomRight * wet) * gain
            mixKaraokeFrame(
                mixed, buffer.getShort(offset) + voiceLeft, buffer.getShort(offset + 2) + voiceRight,
            )
            offset += 4
        }
        mixed.flip()
    }

    override fun pause() {
        capture()?.discardBefore(System.nanoTime())
        clearMix()
        super.pause()
    }

    override fun flush() {
        capture()?.discardBefore(System.nanoTime())
        submittedFrames = 0L
        outputBuffer?.resetClock()
        clearMix()
        super.flush()
    }

    private fun clearMix() {
        mixed.limit(0)
        gain = 0f
        wet = 0f
        voiceEffect.reset()
    }
}

/** 只缩短 K 歌的应用写入队列。设备出现欠载时逐步放宽，避免追求低延迟导致断音。 */
internal class KaraokeOutputBuffer(private val track: AudioTrack) {
    private val normalFrames = track.bufferSizeInFrames
    private val outputTimestamp = AudioTimestamp()
    private var outputClock: KaraokeFrameTime? = null
    private var nextClockCheck = Long.MIN_VALUE
    private var tuned = false
    private var lastRoute: Int? = null
    private var lastUnderruns = 0
    private var nextCheck = 0L
    var bluetooth = false
        private set

    fun resetClock() {
        outputClock = null
        nextClockCheck = Long.MIN_VALUE
    }

    fun playoutTime(submitted: Long, now: Long): Long? {
        if (now >= nextClockCheck) {
            outputClock = if (track.getTimestamp(outputTimestamp)) {
                // 音轨时间戳的帧号为 32 位，和已提交帧数还原到同一个区间。
                val queued = (submitted - outputTimestamp.framePosition) and 0xffffffffL
                val plausible = normalFrames + STEM_SAMPLE_RATE.toLong() / 2
                if (queued <= plausible) KaraokeFrameTime(submitted - queued, outputTimestamp.nanoTime) else null
            } else {
                null
            }
            nextClockCheck = now + 100_000_000L
        }
        return outputClock?.timeAt(submitted)?.takeIf { it >= now - 25_000_000L }
    }

    fun update(karaoke: Boolean) {
        if (!karaoke) {
            if (tuned) {
                track.setBufferSizeInFrames(normalFrames)
                tuned = false
            }
            return
        }
        val now = SystemClock.elapsedRealtime()
        if (tuned && now < nextCheck) return
        val route = track.routedDevice?.type
        val underruns = track.underrunCount
        bluetooth = when (route) {
            AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
            AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER,
            AudioDeviceInfo.TYPE_BLE_BROADCAST, AudioDeviceInfo.TYPE_HEARING_AID -> true
            else -> false
        }
        val current = track.bufferSizeInFrames
        val target = when {
            !tuned || route != lastRoute -> karaokeBufferTarget(track.sampleRate, normalFrames, bluetooth || route == null)
            underruns > lastUnderruns -> minOf(normalFrames, current + track.sampleRate / 50)
            else -> current
        }
        if (target > 0 && target != current) track.setBufferSizeInFrames(target)
        tuned = true
        lastRoute = route
        lastUnderruns = underruns
        nextCheck = now + 500
    }
}

internal fun karaokeBufferTarget(sampleRate: Int, normalFrames: Int, bluetooth: Boolean): Int =
    minOf(normalFrames, sampleRate * (if (bluetooth) 65 else 35) / 1000)

internal fun mixKaraokeFrame(output: ByteBuffer, left: Float, right: Float) {
    val peak = maxOf(abs(left), abs(right))
    val attenuation = if (peak > 32767f) 32767f / peak else 1f
    output.putShort((left * attenuation).roundToInt().toShort())
    output.putShort((right * attenuation).roundToInt().toShort())
}
