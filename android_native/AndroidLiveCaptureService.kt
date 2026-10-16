package com.example.hz_studio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import kotlin.concurrent.thread
import kotlin.math.sqrt

class AndroidLiveCaptureService : Service() {
    companion object {
        const val ACTION_START = "hz.live.START"
        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"
        @Volatile var running = false
        @Volatile var level = 0.0
        @Volatile var status = "Capture arrêtée"
    }

    private var projection: MediaProjection? = null
    private var recorder: AudioRecord? = null
    private var worker: Thread? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != ACTION_START || Build.VERSION.SDK_INT < 29) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (running) return START_NOT_STICKY
        val notificationManager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = "hz_studio_capture"
        notificationManager.createNotificationChannel(
            NotificationChannel(channelId, "Capture audio HZ Studio", NotificationManager.IMPORTANCE_LOW)
        )
        val notification = Notification.Builder(this, channelId)
            .setContentTitle("HZ Studio : capture audio")
            .setContentText("Test du niveau audio des applications compatibles")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true).build()
        try {
            if (Build.VERSION.SDK_INT >= 29) {
                startForeground(327, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
            } else {
                startForeground(327, notification)
            }
        } catch (e: Exception) {
            status = "Service de capture refusé : ${e.message}"
            stopSelf()
            return START_NOT_STICKY
        }
        @Suppress("DEPRECATION")
        val data = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else intent.getParcelableExtra<Intent>(EXTRA_RESULT_DATA)
        if (data == null) { status = "Autorisation absente"; stopSelf(); return START_NOT_STICKY }
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        running = true
        status = "Initialisation de la capture…"
        worker = thread(name = "hz-android-capture") {
            try {
                val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val mp = manager.getMediaProjection(resultCode, data)
                projection = mp
                val config = AudioPlaybackCaptureConfiguration.Builder(mp)
                    .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                    .addMatchingUsage(AudioAttributes.USAGE_GAME)
                    .build()
                val format = AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(44100)
                    .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                    .build()
                val min = AudioRecord.getMinBufferSize(44100, AudioFormat.CHANNEL_IN_STEREO, AudioFormat.ENCODING_PCM_16BIT)
                val record = AudioRecord.Builder()
                    .setAudioFormat(format)
                    .setAudioPlaybackCaptureConfig(config)
                    .setBufferSizeInBytes(maxOf(min, 16384))
                    .build()
                recorder = record
                record.startRecording()
                status = "Capture active : test du niveau audio (pas de sortie transformée)"
                val samples = ShortArray(4096)
                while (running && !Thread.currentThread().isInterrupted) {
                    val n = record.read(samples, 0, samples.size)
                    if (n > 0) {
                        var squares = 0.0
                        for (i in 0 until n) {
                            val sample = samples[i] / 32768.0
                            squares += sample * sample
                        }
                        level = sqrt(squares / n).coerceIn(0.0, 1.0)
                    } else if (n < 0) {
                        status = "Erreur de lecture audio : $n"
                        break
                    }
                }
            } catch (e: Exception) {
                status = "Capture impossible : ${e.message}"
            } finally {
                running = false
                level = 0.0
                try { recorder?.stop() } catch (_: Exception) {}
                try { recorder?.release() } catch (_: Exception) {}
                recorder = null
                try { projection?.stop() } catch (_: Exception) {}
                projection = null
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        worker?.interrupt()
        super.onDestroy()
    }
}
