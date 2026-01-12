# WebSocket Best Practices for Mobile Clients

Best practices for resilient client-server connectivity with WebSockets on mobile platforms, with emphasis on poor bandwidth, poor signal, and app lifecycle handling.

## Connection Management

### 1. Implement robust reconnection logic
- Use exponential backoff with jitter to avoid thundering herd
- Cap maximum retry delay (e.g., 30-60 seconds)
- Reset backoff on successful connection

### 2. Handle network transitions gracefully
- Listen for reachability/network status changes
- Reconnect proactively when network becomes available
- Don't retry when network is unreachable

### 3. Use heartbeats/ping-pong
- Send periodic pings to detect dead connections
- iOS `URLSessionWebSocketTask` has built-in ping support
- Typical interval: 30-60 seconds

## Message Delivery

### 4. Implement message acknowledgment
- Assign unique IDs to messages requiring delivery confirmation
- Buffer unacknowledged messages for replay on reconnection
- Client sends `ack` when message is processed

### 5. Handle message ordering
- Include timestamps for ordering hints
- Design protocol to tolerate out-of-order delivery when possible
- Use sequence numbers if strict ordering is required

## Authentication

### 6. Authenticate early in connection lifecycle
- Send auth immediately after WebSocket opens (before other messages)
- Handle auth errors by closing connection and notifying user
- Store credentials securely (Keychain on iOS)

### 7. Design for reconnection auth
- Session tokens should survive reconnection
- Avoid re-prompting user for credentials on network blips

## Mobile-Specific Concerns

### 8. Respect message size limits
- iOS `URLSessionWebSocketTask`: ~256 KB limit
- Implement server-side truncation for large responses
- Use chunking for large uploads

### 9. Handle app lifecycle
- Disconnect cleanly on background/suspend
- Reconnect on foreground
- Consider background task for critical message delivery

### 10. Optimize for battery
- Avoid aggressive polling or short ping intervals
- Use system push notifications for waking app when possible
- Batch non-urgent messages

## Protocol Design

### 11. Use typed messages with clear structure
- Include `type` field in all messages
- Use consistent naming conventions (snake_case for JSON)
- Version your protocol for future compatibility

### 12. Design idempotent operations
- Replayed messages shouldn't cause duplicate side effects
- Use message IDs for deduplication

### 13. Provide clear error responses
- Distinguish auth errors from protocol errors
- Include actionable error messages
- Define error recovery paths

## Detecting Degraded Connections

### 14. Implement connection quality monitoring
- Track round-trip time (RTT) of ping/pong cycles
- Detect "zombie connections" where TCP is alive but unusable
- If pong doesn't arrive within 2-3x normal RTT, assume connection is degraded

### 15. Use application-level timeouts, not just TCP
- TCP can keep a dead connection open for minutes
- Set aggressive read timeouts (15-30 seconds)
- Treat timeout as connection failure, not just slow response

### 16. Distinguish slow from dead
- Slow connection: increase timeouts, reduce message frequency
- Dead connection: reconnect immediately
- Use progressive timeout increases before declaring dead

## Poor Bandwidth Handling

### 17. Implement message prioritization
- Queue outgoing messages by priority
- Send critical messages (auth, acks) before bulk data
- Drop or defer low-priority messages under congestion

### 18. Support message compression
- Compress payloads over threshold (e.g., 1KB)
- Use per-message compression (WebSocket permessage-deflate)
- Consider protocol-level compression for repetitive structures

### 19. Implement adaptive payload sizing
- Track successful vs failed message deliveries by size
- Dynamically reduce max message size on repeated failures
- Request smaller chunks from server when bandwidth is constrained

### 20. Use delta sync instead of full sync
- Send `last_message_id` to request only new messages
- Server returns diff, not complete state
- Dramatically reduces bandwidth on reconnection

## Intermittent Signal Handling

### 21. Design for "offline-first"
- Queue actions locally when offline
- Sync when connection restored
- Show pending/synced status in UI

### 22. Implement optimistic UI with rollback
- Update UI immediately on user action
- Confirm with server asynchronously
- Rollback UI if server rejects

### 23. Use request coalescing
- Batch multiple pending requests into single message
- Deduplicate redundant requests (e.g., multiple status checks)
- Reduces reconnection burst load

### 24. Handle half-open connections
- Server sends periodic "heartbeat" messages (not just responding to pings)
- Client expects server heartbeat within interval
- Missing server heartbeat triggers reconnection

## App Lifecycle Resilience

### 25. Persist pending messages to disk
- Don't rely solely on in-memory queues
- Write outgoing messages to disk before sending
- Delete from disk only after server ack
- Survives app termination

### 26. Use background URLSession for critical uploads
- iOS continues uploads even after app suspension
- Completion handler called when app relaunched
- Essential for file uploads, not suitable for WebSocket

### 27. Implement graceful degradation on background
- Close WebSocket cleanly before suspension
- Store connection state (last message ID, session info)
- Restore state on foreground, not full re-sync

### 28. Request background execution time for cleanup
- Use `beginBackgroundTask` to complete in-flight operations
- Send pending acks before suspension
- Persist any unsynced state

## Network Transition Handling

### 29. Handle WiFi to Cellular handoffs
- Monitor for network interface changes
- Proactively reconnect on interface change (don't wait for failure)
- May need to re-resolve DNS on new network

### 30. Implement path migration awareness
- New network may have different latency characteristics
- Reset RTT estimates after network change
- Adjust timeouts accordingly

### 31. Handle captive portals
- Detect redirect responses (302 to login page)
- Notify user instead of infinite retry
- Re-check connectivity after user interaction

## Server-Side Resilience

### 32. Implement server-side connection draining
- Before shutdown, send "reconnect" hint to clients
- Allow graceful migration to new server instance
- Clients reconnect to healthy instance

### 33. Use connection affinity with fallback
- Prefer same server for session continuity
- Fall back to any available server if preferred unavailable
- Server-side session state must be shared or recoverable

### 34. Implement circuit breaker pattern
- After N consecutive failures, stop retrying temporarily
- Prevents battery drain on persistent server outage
- Show "service unavailable" instead of endless spinner

## Observability

### 35. Log connection lifecycle events
- Connect, disconnect, reconnect with timestamps
- Failure reasons (timeout, auth, server error)
- Network type at time of event

### 36. Track client-side metrics
- Connection success rate
- Average reconnection time
- Message delivery latency
- Helps identify systemic issues

### 37. Implement user-visible connection status
- Show "Connecting...", "Connected", "Offline" states
- Avoid false "connected" when degraded
- Let user manually trigger reconnection

## Edge Cases

### 38. Handle clock skew
- Don't rely on client timestamp for ordering
- Server assigns authoritative timestamps
- Use relative time (duration) not absolute when possible

### 39. Protect against replay attacks
- Include nonce or timestamp in auth
- Server rejects stale or reused credentials
- Important for security-sensitive operations

### 40. Handle message corruption
- Validate JSON structure before processing
- Reject malformed messages gracefully
- Log for debugging without crashing
