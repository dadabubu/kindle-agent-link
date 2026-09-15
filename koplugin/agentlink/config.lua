-- Public endpoint defaults for Kindle AgentLink (§docs/http-contract.md).
-- Everything that points at your relay lives here; override any of these
-- per device in the plugin settings file (see docs/koreader-install.md).

local Config = {}

Config.DEFAULT_SERVER_URL = "https://your-relay.example.com/agentlink/v1/reading-events"
Config.DEFAULT_EXCERPT_URL = "https://your-relay.example.com/agentlink/v1/excerpts"
Config.DEFAULT_REPLIES_URL = "https://your-relay.example.com/agentlink/v1/replies"
Config.DEFAULT_REPLIES_ACK_URL = "https://your-relay.example.com/agentlink/v1/replies/ack"
Config.DEFAULT_BOOKS_PROBE_URL = "https://your-relay.example.com/agentlink/v1/books/probe"
Config.DEFAULT_BOOKS_UPLOAD_URL = "https://your-relay.example.com/agentlink/v1/books/upload"
Config.DEFAULT_BOOKS_MANIFEST_URL = "https://your-relay.example.com/agentlink/v1/books/manifest"

-- How your agent is addressed on the device. All three are settings-overridable.
Config.DEFAULT_AGENT_NAME = "Agent"
Config.DEFAULT_DEEP_LABEL = "与 Agent 深谈"
Config.DEFAULT_QUICK_LABEL = "快问 Agent"
Config.DEFAULT_BOOKS_LABEL = "%s 书库"

return Config
