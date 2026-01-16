package dev.labs910.voicecode

import android.app.Application
import dev.labs910.voicecode.data.local.ApiKeyManager
import dev.labs910.voicecode.data.local.VoiceCodeDatabase

/**
 * Application class for VoiceCode Android app.
 * Initializes singletons and global state.
 */
class VoiceCodeApplication : Application() {

    lateinit var database: VoiceCodeDatabase
        private set

    lateinit var apiKeyManager: ApiKeyManager
        private set

    override fun onCreate() {
        super.onCreate()

        // Initialize singletons
        database = VoiceCodeDatabase.getInstance(this)
        apiKeyManager = ApiKeyManager(this)

        instance = this
    }

    companion object {
        @Volatile
        private var instance: VoiceCodeApplication? = null

        fun getInstance(): VoiceCodeApplication {
            return instance ?: throw IllegalStateException("Application not initialized")
        }
    }
}
