// PriorityQueueAdmission.swift
// The one place that decides what earns a slot in the priority queue.
//
// The queue is a turn-taking inbox: the sessions where the ball is in the user's
// court. A session enters when a reply lands for a prompt THIS DEVICE sent, and
// leaves when the user sends the next prompt to it. Agents the user did not
// prompt from the device — CLI-launched, recipe-driven, or merely watched — never
// enter on their own; they enter by manual add only.
//
// Extracted from the three inlined `!newAssistantTexts.isEmpty && defaults.bool(…)`
// conditions in SessionSyncManager (one per delivery path: v0.4.0 session_history,
// v0.5.0 session_history, legacy session_updated) so the rule is stated once and
// tested directly. See docs/design/priority-queue-revisit.md.

import Foundation

enum PriorityQueueAdmission {

    /// The session an outbound message hands the turn back to, or `nil` if the
    /// message isn't a prompt. Recognizing this on the wire dictionary rather
    /// than at each call site means every send path is covered by one hook —
    /// typed, voice, headset, menu-bar quick prompt, recipe launch, and whatever
    /// send path is added next.
    ///
    /// Ghost sends (`ghost: true`) still carry `resume_session_id` and still put
    /// the ball in the agent's court, so they count.
    static func promptTarget(ofOutgoing message: [String: Any]) -> String? {
        guard let type = message["type"] as? String else { return nil }

        switch type {
        case "prompt":
            // Resume first: a resume send carries only `resume_session_id`, a
            // new-session send only `new_session_id`.
            let target = (message["resume_session_id"] as? String)
                ?? (message["new_session_id"] as? String)
                ?? (message["session_id"] as? String)
            return normalized(target)
        case "start_recipe":
            return normalized(message["session_id"] as? String)
        default:
            return nil
        }
    }

    /// Whether a batch of freshly-arrived live assistant messages should put the
    /// session in the queue.
    ///
    /// `claimAwaitedReply` is a closure, not a `Bool`, because claiming is
    /// destructive — it consumes the one-shot record of the user's outstanding
    /// prompt. Evaluating it when the feature is off, or when nothing new
    /// arrived, would burn a claim that a later genuine reply needs.
    static func shouldEnqueue(featureEnabled: Bool,
                              hasLiveAssistantMessages: Bool,
                              claimAwaitedReply: () -> Bool) -> Bool {
        guard featureEnabled, hasLiveAssistantMessages else { return false }
        return claimAwaitedReply()
    }

    private static func normalized(_ sessionId: String?) -> String? {
        guard let sessionId = sessionId, !sessionId.isEmpty else { return nil }
        return sessionId.lowercased()
    }
}
