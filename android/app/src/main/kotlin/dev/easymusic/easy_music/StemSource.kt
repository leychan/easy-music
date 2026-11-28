package dev.easymusic.easy_music

import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.Proxy
import java.net.URL

internal val stemContentRange = Regex("""bytes (\d+)-(\d+)/(\d+)""")

internal fun readRemoteStem(
    address: URL,
    output: OutputStream,
    job: StemJob,
    progress: (Double?) -> Unit,
) {
    progress(null)
    var offset = 0L
    var total: Long? = null
    var etag: String? = null
    do {
        job.check()
        val connection = address.openConnection(Proxy.NO_PROXY) as HttpURLConnection
        try {
            // 回环代理与原播放器共用缓存。部分 CDN 即使请求到末尾也只返回固定大小的一段。
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 15000
            connection.readTimeout = 30000
            connection.setRequestProperty("Accept-Encoding", "identity")
            if (offset > 0) connection.setRequestProperty("Range", "bytes=$offset-")
            val status = connection.responseCode
            val length = connection.getHeaderField("Content-Length")?.toLongOrNull()
            val encoding = connection.contentEncoding
            val type = connection.contentType?.substringBefore(';')?.trim()?.lowercase()
            if ((encoding != null && !encoding.equals("identity", ignoreCase = true)) ||
                type?.contains("mpegurl") == true ||
                type in setOf("application/dash+xml", "audio/x-scpls", "text/html", "application/json")) {
                throw StemFailure("format", "当前在线音源无法读取为完整歌曲。")
            }
            val currentTag = connection.getHeaderField("ETag")
            if (etag != null && currentTag != null && etag != currentTag) {
                throw incompleteAudio()
            }
            etag = etag ?: currentTag
            val partBytes = when (status) {
                HttpURLConnection.HTTP_OK -> {
                    if (offset != 0L) throw incompleteAudio()
                    total = length
                    length
                }
                HttpURLConnection.HTTP_PARTIAL -> {
                    val range = stemContentRange.matchEntire(connection.getHeaderField("Content-Range") ?: "")
                        ?: throw incompleteAudio()
                    val (start, end, size) = range.destructured
                    val last = end.toLongOrNull() ?: throw incompleteAudio()
                    val sizeBytes = size.toLongOrNull() ?: throw incompleteAudio()
                    if (start.toLongOrNull() != offset || last < offset || last >= sizeBytes ||
                        (total != null && total != sizeBytes)) {
                        throw incompleteAudio()
                    }
                    total = sizeBytes
                    val bytes = last - offset + 1
                    if (length != null && length != bytes) throw incompleteAudio()
                    bytes
                }
                else -> throw incompleteAudio()
            }
            if (total != null && total > MAX_STEM_BYTES) throw sourceTooLarge()
            val received = connection.inputStream.use { input ->
                copyStemBytes(input, output, job, MAX_STEM_BYTES - offset, partBytes) { bytes ->
                    progress(total?.takeIf { it > 0 }?.let { (offset + bytes).toDouble() / it })
                }
            }
            if (received == 0L) throw incompleteAudio()
            offset += received
        } finally {
            connection.disconnect()
        }
    } while (total?.let { offset < it } == true)
}

internal fun copyStemBytes(
    input: InputStream,
    output: OutputStream,
    job: StemJob,
    limit: Long = MAX_STEM_BYTES.toLong(),
    expected: Long? = null,
    onBytes: (Long) -> Unit = {},
): Long {
    var received = 0L
    val buffer = ByteArray(128 * 1024)
    while (true) {
        job.check()
        val count = input.read(buffer)
        if (count < 0) break
        received += count
        if (received > limit) throw sourceTooLarge()
        if (expected != null && received > expected) throw incompleteAudio()
        output.write(buffer, 0, count)
        onBytes(received)
    }
    if (expected != null && received != expected) throw incompleteAudio()
    return received
}

private fun incompleteAudio() = StemFailure("source", "无法读取完整的在线音频，请重新播放后再试。")

private fun sourceTooLarge() = StemFailure("length", "源文件过大，无法分轨。")
