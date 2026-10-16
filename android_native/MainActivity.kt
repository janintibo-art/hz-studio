package com.example.hz_studio

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.Manifest
import android.content.pm.PackageManager
import android.content.Intent
import android.content.Context
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.app.Activity
import io.flutter.plugin.common.MethodChannel.Result
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
    private val captureRequestCode = 8342
    private val audioPermissionCode = 8343
    private var pendingCaptureResult: Result? = null

    private fun requestScreenCaptureConsent() {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        try {
            startActivityForResult(manager.createScreenCaptureIntent(), captureRequestCode)
        } catch (e: Exception) {
            pendingCaptureResult?.error("CAPTURE", e.message, null)
            pendingCaptureResult = null
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == audioPermissionCode) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                requestScreenCaptureConsent()
            } else {
                pendingCaptureResult?.error("PERMISSION", "Permission audio refusée", null)
                pendingCaptureResult = null
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != captureRequestCode) return
        val pending = pendingCaptureResult
        pendingCaptureResult = null
        if (resultCode == Activity.RESULT_OK && data != null) {
            try {
                val service = Intent(this, AndroidLiveCaptureService::class.java).apply {
                    action = AndroidLiveCaptureService.ACTION_START
                    putExtra(AndroidLiveCaptureService.EXTRA_RESULT_CODE, resultCode)
                    putExtra(AndroidLiveCaptureService.EXTRA_RESULT_DATA, data)
                }
                if (Build.VERSION.SDK_INT >= 26) startForegroundService(service) else startService(service)
                pending?.success(true)
            } catch (e: Exception) {
                pending?.error("CAPTURE", e.message, null)
            }
        } else {
            pending?.success(false)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hz_studio/android_live").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    if (Build.VERSION.SDK_INT < 29) {
                        result.error("VERSION", "Android 10 minimum requis", null)
                    } else if (pendingCaptureResult != null) {
                        result.error("BUSY", "Autorisation déjà demandée", null)
                    } else {
                        pendingCaptureResult = result
                        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), audioPermissionCode)
                        } else {
                            requestScreenCaptureConsent()
                        }
                    }
                }
                "stop" -> {
                    stopService(Intent(this, AndroidLiveCaptureService::class.java))
                    result.success(true)
                }
                "status" -> result.success(mapOf(
                    "running" to AndroidLiveCaptureService.running,
                    "level" to AndroidLiveCaptureService.level,
                    "message" to AndroidLiveCaptureService.status
                ))
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hz_studio/audio_decode")
            .setMethodCallHandler { call, result ->
                val path = call.argument<String>("path")
                if (path.isNullOrBlank()) {
                    result.error("FILE", "Chemin manquant", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "decodePreview" -> thread(name = "hz-decode") {
                        try {
                            val out = File(cacheDir, "hz_import_${System.nanoTime()}.wav")
                            decodePreview(path, out)
                            Handler(Looper.getMainLooper()).post { result.success(out.absolutePath) }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("DECODER", e.message ?: "Décodage impossible", null)
                            }
                        }
                    }
                    "saveWav" -> thread(name = "hz-save") {
                        try {
                            val name = "hz_studio_${System.currentTimeMillis()}.wav"
                            val values = ContentValues().apply {
                                put(MediaStore.Downloads.DISPLAY_NAME, name)
                                put(MediaStore.Downloads.MIME_TYPE, "audio/wav")
                                if (Build.VERSION.SDK_INT >= 29) {
                                    put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                                }
                            }
                            require(Build.VERSION.SDK_INT >= 29) { "Export Android 10 ou plus requis" }
                            val uri = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                                ?: error("Impossible de créer le WAV")
                            try {
                                contentResolver.openOutputStream(uri)?.use { dst ->
                                    File(path).inputStream().use { src -> src.copyTo(dst) }
                                } ?: error("Impossible d'ouvrir le fichier cible")
                            } catch (e: Exception) {
                                contentResolver.delete(uri, null, null)
                                throw e
                            }
                            Handler(Looper.getMainLooper()).post { result.success(name) }
                        } catch (e: Exception) {
                            Handler(Looper.getMainLooper()).post {
                                result.error("EXPORT", e.message ?: "Export impossible", null)
                            }
                        }
                    }
                    else -> result.notImplemented()
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
            RandomAccessFile(output, "rw").use { wav ->
                wav.setLength(0)
                wav.write(ByteArray(44))
                while (!endOutput) {
                    if (!endInput) {
                        val inputIndex = decoder.dequeueInputBuffer(10000)
                        if (inputIndex >= 0) {
                            val input = decoder.getInputBuffer(inputIndex)!!
                            input.clear()
                            val at = extractor.sampleTime
                            if (at < 0) {
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
                            if (info.size > 0) {
                                buffer.position(info.offset)
                                buffer.limit(info.offset + info.size)
                                buffer.order(ByteOrder.LITTLE_ENDIAN)
                                val frameBytes = channels * 2
                                val frames = info.size / frameBytes
                                for (i in 0 until frames) {
                                    for (ch in 0 until channels) {
                                        val sample = buffer.short.toInt()
                                        if (ch < 2) {
                                            wav.write(sample and 0xff)
                                            wav.write((sample ushr 8) and 0xff)
                                            bytesWritten += 2
                                        }
                                    }
                                }
                            }
                            endOutput = info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            decoder.releaseOutputBuffer(outputIndex, false)
                        }
                    }
                }
                require(bytesWritten > 0) { "Le fichier ne contient pas de PCM lisible" }
                wav.seek(0)
                fun writeLE16(v: Int) { wav.write(v and 255); wav.write((v ushr 8) and 255) }
                fun writeLE32(v: Long) { repeat(4) { wav.write(((v ushr (8 * it)) and 255).toInt()) } }
                wav.writeBytes("RIFF"); writeLE32(bytesWritten + 36); wav.writeBytes("WAVEfmt ")
                writeLE32(16); writeLE16(1); writeLE16(minOf(channels, 2)); writeLE32(sampleRate.toLong()); writeLE32((sampleRate * minOf(channels, 2) * 2).toLong())
                writeLE16(minOf(channels, 2) * 2); writeLE16(16); wav.writeBytes("data"); writeLE32(bytesWritten)
            }
        } finally {
            try { codec?.stop() } catch (_: Exception) {}
            codec?.release()
            extractor.release()
        }
    }
}
