# Coding Standards

## Naming Conventions

### JSON (External Interface)
- Use **snake_case** for all JSON keys
- Examples: `session_id`, `working_directory`, `claude_session_id`

### Clojure (Internal)
- Use **kebab-case** for all keywords and identifiers
- Examples: `:session-id`, `:working-directory`, `:claude-session-id`

### Coercion at Boundaries
- **Parse JSON → Clojure**: Convert `snake_case` keys to `kebab-case` keywords
- **Generate Clojure → JSON**: Convert `kebab-case` keywords to `snake_case` keys
- Use Cheshire's `:key-fn` option for automatic conversion

### Swift/iOS
- Use **camelCase** for Swift properties (Swift convention)
- Use **snake_case** for JSON communication with backend
- Examples: Swift `claudeSessionId` ↔ JSON `session_id` ↔ Clojure `:session-id`
