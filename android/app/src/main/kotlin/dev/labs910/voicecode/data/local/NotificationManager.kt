package dev.labs910.voicecode.data.local

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import dev.labs910.voicecode.R
import dev.labs910.voicecode.presentation.ui.MainActivity

/**
 * Notification manager for showing Claude response notifications.
 * Equivalent to iOS NotificationManager.
 */
class VoiceCodeNotificationManager(
    private val context: Context
) {
    companion object {
        private const val CHANNEL_ID_RESPONSES = "voice_code_responses"
        private const val CHANNEL_NAME_RESPONSES = "Claude Responses"
        private const val CHANNEL_DESC_RESPONSES = "Notifications when Claude responds to your prompts"

        private const val CHANNEL_ID_SERVICE = "voice_code_service"
        private const val CHANNEL_NAME_SERVICE = "VoiceCode Service"
        private const val CHANNEL_DESC_SERVICE = "Background service for voice processing"

        private const val NOTIFICATION_ID_SERVICE = 1
        private const val NOTIFICATION_ID_RESPONSE_BASE = 1000
    }

    private val notificationManager = NotificationManagerCompat.from(context)
    private var responseNotificationId = NOTIFICATION_ID_RESPONSE_BASE

    init {
        createNotificationChannels()
    }

    /**
     * Create notification channels for Android 8.0+.
     */
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val systemNotificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager

            // Response notifications channel
            val responsesChannel = NotificationChannel(
                CHANNEL_ID_RESPONSES,
                CHANNEL_NAME_RESPONSES,
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = CHANNEL_DESC_RESPONSES
                setShowBadge(true)
            }
            systemNotificationManager.createNotificationChannel(responsesChannel)

            // Service notifications channel (low importance, no sound)
            val serviceChannel = NotificationChannel(
                CHANNEL_ID_SERVICE,
                CHANNEL_NAME_SERVICE,
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = CHANNEL_DESC_SERVICE
                setShowBadge(false)
            }
            systemNotificationManager.createNotificationChannel(serviceChannel)
        }
    }

    /**
     * Check if notification permission is granted.
     */
    fun hasNotificationPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    /**
     * Show a notification for a Claude response.
     *
     * @param sessionName Name of the session
     * @param preview Preview text of the response
     * @param sessionId Session ID for deep linking
     */
    fun showResponseNotification(
        sessionName: String,
        preview: String,
        sessionId: String
    ) {
        if (!hasNotificationPermission()) return

        // Create intent for tapping the notification
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra("session_id", sessionId)
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            sessionId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID_RESPONSES)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(sessionName)
            .setContentText(preview)
            .setStyle(NotificationCompat.BigTextStyle().bigText(preview))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        notificationManager.notify(responseNotificationId++, notification)

        // Wrap notification ID to avoid overflow
        if (responseNotificationId > NOTIFICATION_ID_RESPONSE_BASE + 1000) {
            responseNotificationId = NOTIFICATION_ID_RESPONSE_BASE
        }
    }

    /**
     * Create a notification for the foreground service.
     */
    fun createServiceNotification(): android.app.Notification {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }

        val pendingIntent = PendingIntent.getActivity(
            context,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(context, CHANNEL_ID_SERVICE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle("VoiceCode")
            .setContentText("Connected to voice-code backend")
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .build()
    }

    /**
     * Cancel all response notifications.
     */
    fun cancelAllResponseNotifications() {
        for (id in NOTIFICATION_ID_RESPONSE_BASE until responseNotificationId) {
            notificationManager.cancel(id)
        }
        responseNotificationId = NOTIFICATION_ID_RESPONSE_BASE
    }

    /**
     * Cancel a specific notification.
     */
    fun cancelNotification(id: Int) {
        notificationManager.cancel(id)
    }
}
