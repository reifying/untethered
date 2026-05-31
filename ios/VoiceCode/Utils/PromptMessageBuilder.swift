// PromptMessageBuilder.swift
// Pure construction of the `prompt` wire message, extracted from
// ConversationView so the new-vs-resume and ghost branches are unit-testable.
//
// Ghost prompts (tmux-untethered-5hw): when `ghost` is true the backend treats
// `text` as a task description, forks the resumed session to author the real
// prompt P, and injects P back into the session. Ghost is RESUMED-SESSION ONLY
// (design §3.3) — it is never attached to a `new_session_id` send.

import Foundation

enum PromptMessageBuilder {
    /// Build the wire dictionary for a `prompt` message.
    ///
    /// - Parameters:
    ///   - text: The user's text (a literal prompt, or a task description when `ghost`).
    ///   - sessionId: Lowercased session UUID string.
    ///   - workingDirectory: Session working directory.
    ///   - isNewSession: `true` → `new_session_id` + `provider`; `false` → `resume_session_id`.
    ///   - provider: Provider id for new sessions (ignored when resuming).
    ///   - systemPrompt: Optional system prompt; included only when non-empty.
    ///   - ghost: When `true` AND resuming, adds `ghost: true`. Ignored for new sessions.
    static func build(
        text: String,
        sessionId: String,
        workingDirectory: String,
        isNewSession: Bool,
        provider: String,
        systemPrompt: String,
        ghost: Bool = false
    ) -> [String: Any] {
        var message: [String: Any] = [
            "type": "prompt",
            "text": text,
            "working_directory": workingDirectory
        ]

        if isNewSession {
            // New sessions create a fresh .jsonl; ghost has no meaning here and
            // is deliberately dropped so a stale toggle can't ghost a new send.
            message["new_session_id"] = sessionId
            message["provider"] = provider
        } else {
            message["resume_session_id"] = sessionId
            if ghost {
                message["ghost"] = true
            }
        }

        if !systemPrompt.isEmpty {
            message["system_prompt"] = systemPrompt
        }

        return message
    }
}
