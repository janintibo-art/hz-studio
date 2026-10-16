package com.example.hz_studio

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteOrder
import kotlin.concurrent.thread

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hz_studio/audio_decode").setMethodCallHandler { call, result ->
            if (call.method != "decodePreview") { result.notImplemented(); return@setMethodCallHandler }
            val path = call.argument<String>("path")
            if (path.isNullOrBlank()) { result.error("FILE", "Chemin manquant", null); return@setMethodCallHandler }
            thread(name = "hz-decode") {
                try {
                    val out = File(cacheDir, "hz_import_${System.nanoTime()}.wav")
                    decodePreview(path, out)
                    Handler(Looper.getMainLooper()).post { result.success(out.absolutePath) }
                } catch (e: Exception) {
                    Handler(Looper.getMainLooper()).post { result.error("DECODER", e.message ?: "Décodage impossible", null) }
                }
            }
        }
    }

    private fun decodePreview(path: String, output: File) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            var selected = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val f = extractor.getTrackFormat(i)
                if (f.getString(MediaFormat.KEY_MIME)?.startsWith("audio/") == true) {
                    selected = i; format = f; break
                }
            }
            if (selected < 0 || format == null) error("Aucune piste audio décodable")
            extractor.selectTrack(selected)
            val mime = format.getString(MediaFormat.KEY_MIME)!!
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(format, null, null, 0)
            decoder.start()
            var sampleRate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            var channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            require(sampleRate in 8000..96000 && channels in 1..8) { "Format de sortie non pris en charge" }
            val info = MediaCodec.BufferInfo()
            var endInput = false
            var endOutput = false
            var bytesWritten = 0L
            val maxDurationUs = 20_000_000L
            RandomAccessFile(output, "rw").use { wav ->
                wav.setLength(0)
                wav.write(ByteArray(44))
                var spins = 0
                while (!endOutput && spins++ < 200000) {
                    if (!endInput) {
                        val inputIndex = decoder.dequeueInputBuffer(10000)
                        if (inputIndex >= 0) {
                            val input = decoder.getInputBuffer(inputIndex)!!
                            input.clear()
                            val at = extractor.sampleTime
                            if (at < 0 || at >= maxDurationUs) {
                                decoder.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                endInput = true
                            } else {
                                val size = extractor.readSampleData(input, 0)
                                if (size < 0) {
                                    decoder.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                    endInput = true
                                } else {
                                    decoder.queueInputBuffer(inputIndex, 0, size, at, 0)
                                    extractor.advance()
                                }
                            }
                        }
                    }
                    val outputIndex = decoder.dequeueOutputBuffer(info, 10000)
                    when (outputIndex) {
                        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val of = decoder.outputFormat
                            sampleRate = of.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = of.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            val encoding = if (of.containsKey(MediaFormat.KEY_PCM_ENCODING)) of.getInteger(MediaFormat.KEY_PCM_ENCODING) else 2
                            require(encoding == 2) { "Ce décodeur ne fournit pas du PCM 16 bits" }
                            require(sampleRate in 8000..96000 && channels in 1..8) { "Audio décodé non pris en charge" }
                        }
                        else -> if (outputIndex >= 0) {
                            val buffer = decoder.getOutputBuffer(outputIndex)!!
                            if (info.size > 0 && info.presentationTimeUs < maxDurationUs) {
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                buffer.order(ByteOrder.LITTLE_ENDIAN)
                                val frameBytes = channels * 2
                                val frames = info.size / frameBytes
                                for (i in 0 until frames) {
                                    var sum = 0
                                    for (ch in 0 until channels) sum += buffer.short.toInt()
                                    val mono = (sum / channels).toShort().toInt()
                                    wav.write(mono and 0xff)
                                    wav.write((mono ushr 8) and 0xff)
                                    bytesWritten += 2
                                }
                            }
                            endOutput = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0 || info.presentationTimeUs >= maxDurationUs
                            decoder.releaseOutputBuffer(outputIndex, false)
                        }
                    }
                }
                require(bytesWritten > 0) { "Le fichier ne contient pas de PCM lisible" }
                wav.seek(0)
                fun writeLE16(v: Int) { wav.write(v and 255); wav.write((v ushr 8) and 255) }
                fun writeLE32(v: Long) { repeat(4) { wav.write(((v ushr (8 * it)) and 255).toInt()) } }
                wav.writeBytes("RIFF"); writeLE32(bytesWritten + 36); wav.writeBytes("WAVEfmt ")
                writeLE32(16); writeLE16(1); writeLE16(1); writeLE32(sampleRate.toLong()); writeLE32((sampleRate * 2).toLong())
                writeLE16(2); writeLE16(16); wav.writeBytes("data"); writeLE32(bytesWritten)
            }
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            codec?.release()
            extractor.release()
        }
    }
}
