# TerrapinPilot

TerrapinPilot is an agent-client protocol server for Xcode 27 that runs against any OpenAI-compatible endpoint, including local models. Build your own custom harness.

## What is TerrapinPilot?

TerrapinPilot is a self-hosted coding agent that plugs directly into Xcode. It speaks the **Agent Client Protocol (ACP)** over `stdin`/`stdout`, so Xcode can launch it as a custom agent and drive it with plain JSON-RPC. On the other side, it talks to **any OpenAI-compatible chat-completions server** — `llama.cpp`, LM Studio, an `mlx` server, or a remote endpoint — which means you can run the whole thing on your own hardware with a local model.

In short:

```
Xcode  ⇄  (ACP / JSON-RPC)  ⇄  TerrapinPilot  ⇄  (OpenAI-compatible HTTP)  ⇄  your model server
```

### What it can do

- **Read, edit, build, test, and debug** the project open in Xcode through Xcode's native MCP tools (discovered at runtime via `xcrun mcpbridge`).
- **Browse the web** with built-in `web_fetch` and `web_search` tools (Tavily when `TAVILY_API_KEY` is set, DuckDuckGo otherwise).
- **Run a full agentic loop**: prompt the model, execute the tool calls it requests, feed the results back, and repeat until it produces a final answer (up to 50 turns).
- **Stream** answer and thinking tokens to Xcode as they are generated.
- **Stay within the model's context window** by auto-detecting the server's context length and compacting older history when it gets close.
- **Reuse the server's KV cache** by pinning each session to a stable slot (llama.cpp), so follow-up turns only process the delta.
- **Resume previous sessions** — session state (working directory + chat history) is persisted to `~/.terrapinpilot/sessions/`, so `session/load` restores a conversation after a restart. Sessions not updated for 30 days are removed automatically on startup.
- **Pick up project instructions** from an `AGENTS.md` file in the working directory.
- **Load skills** — reusable instruction packs (`SKILL.md` files) discovered from the project, user, and bundled directories, and loaded on demand via the `use_skill` tool.

## How it works

When Xcode sends a prompt, TerrapinPilot:

1. Loads (or creates) the session's chat history and builds the system prompt from the bundled template, injecting the working directory and any `AGENTS.md` instructions.
2. Opens the Xcode workspace up front so workspace tools work on the first call.
3. Sends the history to the model's `/v1/chat/completions` endpoint along with all available tools, streaming the response.
4. If the model returns tool calls, it executes each one (Xcode MCP tools or web tools), appends the results to the history, and loops back to step 3.
5. When the model returns a final answer, it streams the text to Xcode and saves the updated history.

The Xcode tools are not hard-coded. TerrapinPilot spawns `xcrun mcpbridge`, performs the MCP handshake, and pulls the live tool list from Xcode, so it automatically supports whatever tools your Xcode build exposes.

## Requirements

- macOS 14 or later
- Xcode 27 (provides `xcrun mcpbridge` and the ACP agent host)
- Swift 6.4 toolchain
- A running OpenAI-compatible server (`llama.cpp`, LM Studio, `mlx` server, etc.)

## Building

```sh
swift build
```

The executable is produced at `.build/debug/terrapinpilot`. You can also run it directly with:

```sh
swift run terrapinpilot
```

## Configuration

TerrapinPilot is configured with CLI arguments, which take precedence over environment variables.

| Flag | Environment variable | Default | Description |
| --- | --- | --- | --- |
| `--server` | `AI_SERVER_URL` | `http://localhost:8080` | Base URL of the OpenAI-compatible server. The client posts to `<server>/v1/chat/completions`. |
| `--model` | `AI_MODEL` | `default` | Model name sent in each chat-completion request. |
| `--context-window` | `AI_CONTEXT_WINDOW` | auto-detected | Override the context window size (in tokens). By default it is read from the server's `/v1/models` endpoint. |
| `--slots` | `AI_SLOTS` | `1` | Number of server-side context slots (llama.cpp `-np` / `n_parallel`). Sessions are pinned to a slot so the KV cache is reused across turns. |
| `--debug-log` | `AI_DEBUG_LOG` | `false` | Write each request body to `~/.terrapinpilot/logs/NNNN.json` for prefix-stability debugging. |
| `--default-client` | `AI_DEFAULT_CLIENT` | `xcode` | Client assumed when the connecting ACP client does not identify itself (`xcode` or `generic`). |
| `--skills-dir` | `AI_SKILLS_DIR` | none | Additional skill directories. The flag is repeatable; the environment variable is colon-separated. |

One additional, optional variable:

| Variable | Description |
| --- | --- |
| `TAVILY_API_KEY` | If set, `web_search` uses the Tavily API; otherwise it falls back to DuckDuckGo. |

## Usage

1. **Start a local model server.** For example, with `llama.cpp`:

   ```sh
   llama-server -m /path/to/model.gguf -np 4 -c 32768 --port 8080
   ```

2. **Run TerrapinPilot**, pointing it at the server:

   ```sh
   terrapinpilot --server http://localhost:8080 --model default --slots 4
   ```

3. **Point Xcode at it.** Xcode 27 launches the binary as a custom ACP agent and communicates over `stdin`/`stdout`. From there you can ask it to read, edit, build, and test your project.

### ACP protocol

TerrapinPilot reads one JSON-RPC message per line from `stdin` and writes JSON-RPC responses and notifications to `stdout`. It handles:

| Method | Behavior |
| --- | --- |
| `initialize` | Returns the protocol version, agent capabilities, and agent info. |
| `session/new` | Creates a session (returns a `sessionId`) and records the working directory. |
| `session/load` | Restores a persisted session and replays its conversation as `session/update` notifications, then returns. |
| `session/delete` | Removes a persisted session. Deleting an unknown session succeeds silently. |
| `session/prompt` | Runs an agent turn, streaming `session/update` notifications (`agent_message_chunk`, `agent_thought_chunk`), then returns `stopReason: end_turn`. |
| `session/cancel` | Returns `stopReason: cancelled`. |

### Client detection

On `initialize`, TerrapinPilot reads the client's `clientInfo` (name/title) to identify the connecting client. Xcode gets the Xcode-specific system prompt and the `xcrun mcpbridge` toolset (spawned lazily on the first `session/new`); any other ACP client (VS Code, Zed, JetBrains, ...) gets a generic prompt and the client-agnostic tools (native ACP file tools + web tools). When a client does not identify itself, `--default-client` decides.

## Tools

- **Xcode MCP tools** — discovered at runtime from `xcrun mcpbridge` (read, edit, build, test, debug, previews, and more). TerrapinPilot auto-injects the `workspaceIdentifier` and `tabIdentifier` so the model does not have to supply them.
- **`web_fetch`** — fetches an HTTP/HTTPS URL and returns its text content.
- **`web_search`** — searches the live web (Tavily or DuckDuckGo).
- **`use_skill`** — loads the full instructions of a skill from the `AVAILABLE SKILLS` catalog in the system prompt.

## Skills

TerrapinPilot supports **skills**: reusable instruction packs stored as markdown files. A skill is a directory containing a `SKILL.md` file with YAML frontmatter:

```markdown
---
name: git-release-notes
description: Generate release notes from git history. Use when the user asks for changelogs or release notes.
---
# Git Release Notes
1. Run `git log --oneline <last-tag>..HEAD` ...
2. Group commits by type ...
```

Skills are discovered from these locations (highest precedence first; the first definition of a name wins):

| Location | Scope |
| --- | --- |
| `<workspace>/.terrapinpilot/skills/<name>/` | Project — commit to the repo to share with the team |
| `~/.terrapinpilot/skills/<name>/` | User — personal, applies to all projects |
| `--skills-dir` / `AI_SKILLS_DIR` (colon-separated) | Extra directories |
| Bundled `Resources/skills/<name>.md` | Shipped with the binary |

Only each skill's name and description are injected into the system prompt (the `AVAILABLE SKILLS` section). When a request matches a skill's description, the model calls `use_skill` to load the full instructions. A skill may reference sibling files in its directory (scripts, templates, reference docs), which the model can open with `read_file`.

Bundled skills use a flat layout — one uniquely named `.md` file per skill (e.g. `Resources/skills/git-commit.md`) — because the Swift build system flattens package resource directories into the bundle root, so two `SKILL.md` files in nested directories would collide. The frontmatter `name` still wins; the file's base name is the fallback.

To create a custom skill:

```sh
mkdir -p ~/.terrapinpilot/skills/git-release-notes
# then write ~/.terrapinpilot/skills/git-release-notes/SKILL.md
```

New skills are picked up when a new session starts.

## Testing TerrapinPilot

To test that TerrapinPilot can successfully connect with the AI server, enter the following via stdin:

```
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"session/prompt","params":{"sessionId":"debug1","cwd":"/tmp","prompt":"Reply with exactly: one"}}
{"jsonrpc":"2.0","id":3,"method":"session/prompt","params":{"sessionId":"debug1","prompt":"Reply with exactly: two"}}
```

### `/debug` command

To replay raw JSON to the ACP client without involving the model, send `/debug <file>` as a prompt. The file holds one JSON object per `---`-delimited block, and each object is passed straight through `sendJSON` to the client (the session history is left untouched):

```
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": { "sessionId": "debug1", "update": { "sessionUpdate": "agent_message_chunk", "content": { "type": "text", "text": "hello" } } }
}
---
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": { "sessionId": "debug1", "update": { "sessionUpdate": "agent_thought_chunk", "content": { "type": "text", "text": "thinking..." } } }
}
```

### `/compact` command

To compact a session's history on demand, send `/compact` as a prompt. Automatic compaction only fires when the estimated token count exceeds 90% of the context window; `/compact` bypasses that threshold and trims the conversation down to the most recent messages that fit within half the window. The outcome is reported through the usual compaction notifications, and the compacted history is saved to the session.

## Project structure

```
TerrapinPilot/
├── Package.swift
├── LICENSE
├── README.md
└── Sources/
    ├── Agent/
    │   ├── Agent.swift                  # Agentic execution loop
    │   ├── LLMClient.swift              # LLM client protocol + response types
    │   └── OpenAICompatibleClient.swift # SSE streaming client for /v1/chat/completions
    ├── CLI/
    │   ├── main.swift                   # Entry point: wires config, tools, agent, server
    │   ├── ACPServer.swift              # ACP JSON-RPC server over stdin/stdout
    │   ├── Config.swift                 # CLI args + env var configuration
    │   └── Resources/
    │       ├── system_prompt_xcode.txt  # Xcode-specific system prompt template
    │       ├── system_prompt_generic.txt# Generic (non-Xcode) system prompt template
    │       └── skills/                  # Bundled skills (one <name>.md per skill)
    ├── Enums/
    │   └── MCPError.swift
    ├── Helpers/
    │   ├── ContextManager.swift         # Context-window detection + history compaction
    │   └── SkillCatalog.swift           # Skill discovery + SKILL.md frontmatter parsing
    ├── Logger/
    │   ├── Loggable.swift               # Logging protocol
    │   ├── OSLogger.swift               # os.Logger implementation
    │   └── ConsoleLogger.swift          # stderr implementation
    ├── Stores/
    │   ├── ChatMessage.swift            # Chat message + tool-call models
    │   ├── ClientKind.swift             # ACP client detection (Xcode vs. generic)
    │   ├── SessionStore.swift           # Per-session history + working directory
    │   └── ToolDefinition.swift         # OpenAI-compatible tool schema models
    └── Tools/
        ├── ToolProvider.swift           # Tool provider protocol + registry
        ├── WebTools.swift               # web_fetch + web_search
        ├── SkillTools.swift             # use_skill
        └── XcodeMCPBridgeClient.swift   # xcrun mcpbridge MCP client
```

## License

GPL v3 — see [LICENSE](LICENSE).
