package dev.easymusic.easy_music

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.exp

internal const val DEFAULT_MICROPHONE_REVERB = 0.18f

/** K 歌人声处理。干声直接输出，短房间混响通过并行延迟线叠加。 */
internal class KaraokeVoiceEffect(sampleRate: Int) {
    private val highPass = exp(-2.0 * PI * 90.0 / sampleRate).toFloat()
    private val lowPass = (1.0 - exp(-2.0 * PI * 7500.0 / sampleRate)).toFloat()
    private val envelopeRelease = exp(-1.0 / (0.045 * sampleRate)).toFloat()
    private val gateRelease = (1.0 - exp(-1.0 / (0.055 * sampleRate))).toFloat()
    private val leftEarly = DampedReflection(sampleRate * 11 / 1000, 0.56f)
    private val leftLate = DampedReflection(sampleRate * 23 / 1000, 0.64f)
    private val rightEarly = DampedReflection(sampleRate * 17 / 1000, 0.60f)
    private val rightLate = DampedReflection(sampleRate * 29 / 1000, 0.65f)
    private val leftDiffusion = RoomDiffusion(sampleRate * 4 / 1000)
    private val rightDiffusion = RoomDiffusion(sampleRate * 7 / 1000)
    private var previousInput = 0f
    private var highPassed = 0f
    private var voiceBand = 0f
    private var envelope = 0f
    private var quietGain = 0.18f

    var dry = 0f
        private set
    var roomLeft = 0f
        private set
    var roomRight = 0f
        private set

    fun process(input: Float) {
        // 削弱低频隆隆声和高频嘶声，再平滑压低换气或停顿里的底噪。
        highPassed = highPass * (highPassed + input - previousInput)
        previousInput = input
        voiceBand += (highPassed - voiceBand) * lowPass
        envelope = maxOf(abs(voiceBand), envelope * envelopeRelease)
        val activity = ((envelope - 48f) / 192f).coerceIn(0f, 1f)
        val target = 0.18f + 0.82f * activity * activity * (3f - 2f * activity)
        quietGain = if (target > quietGain) target else quietGain + (target - quietGain) * gateRelease
        dry = voiceBand * quietGain
        val left1 = leftEarly.process(dry)
        val left2 = leftLate.process(dry)
        val right1 = rightEarly.process(dry)
        val right2 = rightLate.process(dry)
        roomLeft = leftDiffusion.process(left1 * 0.45f + left2 * 0.35f + right1 * 0.10f)
        roomRight = rightDiffusion.process(right1 * 0.45f + right2 * 0.35f + left1 * 0.10f)
    }

    fun reset() {
        previousInput = 0f
        highPassed = 0f
        voiceBand = 0f
        envelope = 0f
        quietGain = 0.18f
        dry = 0f
        roomLeft = 0f
        roomRight = 0f
        leftEarly.reset()
        leftLate.reset()
        rightEarly.reset()
        rightLate.reset()
        leftDiffusion.reset()
        rightDiffusion.reset()
    }
}

private class DampedReflection(frames: Int, private val feedback: Float) {
    private val buffer = FloatArray(frames)
    private var index = 0
    private var filtered = 0f

    fun process(input: Float): Float {
        val delayed = buffer[index]
        // 每次反射让高频更快衰减，避免听起来像重复的回声。
        filtered += (delayed - filtered) * 0.55f
        buffer[index] = input + filtered * feedback
        if (++index == buffer.size) index = 0
        return delayed
    }

    fun reset() {
        buffer.fill(0f)
        index = 0
        filtered = 0f
    }
}

private class RoomDiffusion(frames: Int) {
    private val buffer = FloatArray(frames)
    private var index = 0

    fun process(input: Float): Float {
        val delayed = buffer[index]
        val value = input + delayed * 0.5f
        buffer[index] = value
        if (++index == buffer.size) index = 0
        return delayed - value * 0.5f
    }

    fun reset() {
        buffer.fill(0f)
        index = 0
    }
}
