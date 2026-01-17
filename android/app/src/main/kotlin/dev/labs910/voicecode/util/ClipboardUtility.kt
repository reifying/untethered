package dev.labs910.voicecode.util

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Utilities for clipboard operations.
 * Corresponds to iOS ClipboardUtility.swift.
 */
object ClipboardUtility {

    private const val CLIP_LABEL = "VoiceCode"

    /**
     * Copy text to the system clipboard.
     *
     * @param context Android context
     * @param text Text to copy
     */
    fun copy(context: Context, text: String) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = ClipData.newPlainText(CLIP_LABEL, text)
        clipboard.setPrimaryClip(clip)
    }

    /**
     * Get text from the system clipboard.
     *
     * @param context Android context
     * @return Clipboard text, or null if empty or not text
     */
    fun paste(context: Context): String? {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return null

        if (clip.itemCount == 0) return null

        return clip.getItemAt(0).text?.toString()
    }

    /**
     * Check if the clipboard has text content.
     *
     * @param context Android context
     * @return True if clipboard contains text
     */
    fun hasText(context: Context): Boolean {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        return clipboard.hasPrimaryClip() &&
                clipboard.primaryClipDescription?.hasMimeType("text/plain") == true
    }

    /**
     * Clear the clipboard.
     *
     * @param context Android context
     */
    fun clear(context: Context) {
        val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            clipboard.clearPrimaryClip()
        } else {
            // Fallback for older Android versions: set empty clip
            val emptyClip = ClipData.newPlainText("", "")
            clipboard.setPrimaryClip(emptyClip)
        }
    }

    /**
     * Trigger a success haptic feedback for copy operations.
     *
     * @param context Android context
     */
    fun triggerSuccessHaptic(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val vibratorManager = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
            val vibrator = vibratorManager.defaultVibrator
            vibrator.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_CLICK))
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            @Suppress("DEPRECATION")
            val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            vibrator.vibrate(VibrationEffect.createOneShot(10, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            val vibrator = context.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            @Suppress("DEPRECATION")
            vibrator.vibrate(10)
        }
    }

    /**
     * Copy text and trigger haptic feedback.
     *
     * @param context Android context
     * @param text Text to copy
     */
    fun copyWithHaptic(context: Context, text: String) {
        copy(context, text)
        triggerSuccessHaptic(context)
    }
}
