package dev.labs910.voicecode.presentation.ui

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.labs910.voicecode.presentation.ui.theme.VoiceCodeTheme

/**
 * Activity that receives share intents from other apps.
 * Equivalent to iOS Share Extension.
 */
class ShareReceiverActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val sharedContent = extractSharedContent(intent)

        setContent {
            VoiceCodeTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background
                ) {
                    ShareReceiverScreen(
                        sharedContent = sharedContent,
                        onUpload = { content ->
                            // TODO: Upload content to backend
                            finish()
                        },
                        onCancel = { finish() }
                    )
                }
            }
        }
    }

    private fun extractSharedContent(intent: Intent): SharedContent? {
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                when {
                    intent.type?.startsWith("text/") == true -> {
                        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                        text?.let { SharedContent.Text(it) }
                    }
                    else -> {
                        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                        uri?.let { SharedContent.File(it) }
                    }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                uris?.let { SharedContent.Files(it) }
            }
            else -> null
        }
    }
}

sealed class SharedContent {
    data class Text(val text: String) : SharedContent()
    data class File(val uri: Uri) : SharedContent()
    data class Files(val uris: List<Uri>) : SharedContent()
}

@Composable
fun ShareReceiverScreen(
    sharedContent: SharedContent?,
    onUpload: (SharedContent) -> Unit,
    onCancel: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text(
            text = "Share to VoiceCode",
            style = MaterialTheme.typography.headlineSmall
        )

        Spacer(modifier = Modifier.height(24.dp))

        if (sharedContent != null) {
            Card(
                modifier = Modifier.fillMaxWidth()
            ) {
                Column(
                    modifier = Modifier.padding(16.dp)
                ) {
                    Text(
                        text = when (sharedContent) {
                            is SharedContent.Text -> "Text content"
                            is SharedContent.File -> "1 file"
                            is SharedContent.Files -> "${sharedContent.uris.size} files"
                        },
                        style = MaterialTheme.typography.titleMedium
                    )

                    if (sharedContent is SharedContent.Text) {
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = sharedContent.text.take(100) +
                                if (sharedContent.text.length > 100) "..." else "",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                OutlinedButton(
                    onClick = onCancel,
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Cancel")
                }

                Button(
                    onClick = { onUpload(sharedContent) },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Upload")
                }
            }
        } else {
            Text(
                text = "No content to share",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.error
            )

            Spacer(modifier = Modifier.height(16.dp))

            OutlinedButton(onClick = onCancel) {
                Text("Close")
            }
        }
    }
}
