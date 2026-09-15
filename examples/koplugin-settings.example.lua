-- Kindle AgentLink — example device settings file.
-- Copy to the device as koreader/settings/agentlink.lua and fill in real
-- values. Every key is optional; keys you omit fall back to the defaults
-- in agentlink/config.lua.

return {
    -- Bearer token shared with your relay. Required.
    token = "rotate-me-please",

    -- Relay endpoints (all default to https://your-relay.example.com/agentlink/v1/...).
    -- server_url       = "https://relay.example.org/agentlink/v1/reading-events",
    -- excerpt_url      = "https://relay.example.org/agentlink/v1/excerpts",
    -- replies_url      = "https://relay.example.org/agentlink/v1/replies",
    -- replies_ack_url  = "https://relay.example.org/agentlink/v1/replies/ack",
    -- books_probe_url  = "https://relay.example.org/agentlink/v1/books/probe",
    -- books_upload_url = "https://relay.example.org/agentlink/v1/books/upload",
    -- books_manifest_url = "https://relay.example.org/agentlink/v1/books/manifest",

    -- Display names (settings override the built-in defaults).
    agent_name = "Agent",
    deep_entry_label = "与 Agent 深谈",
    quick_entry_label = "快问 Agent",
}
