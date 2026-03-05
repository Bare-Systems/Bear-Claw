# Review and Enhancement Plan for **BearClaw**

## Existing Architecture

BearClaw is a self‑hostable AI agent runtime written in Zig that aims for a tiny binary with **zero dependencies beyond the Zig standard library**【932555140858001†L0-L6】. The repository is designed around the principle of **Agent‑Driven Hyper Development (ADHD)** — agents should be able to build, test and even modify the BearClaw runtime via the MCP (Model Context Protocol) server【932555140858001†L26-L44】.  Key points from the current architecture are:

### Providers and Models

* `provider.zig` defines a `Provider` abstraction with built‑in backends for **Anthropic/Claude, OpenAI/ChatGPT, OpenRouter, Ollama and an echo provider**.  A `Router` can fall back across multiple providers; `AnyProvider` hides the concrete implementation behind a vtable.  The provider supports tool‑calling by translating tool‑use structures between the provider’s native format and the internal OpenAI‑style JSON representation, enabling the model to return `tool_calls` which the agent can dispatch【932555140858001†L413-L447】.

### Agent Loop

* The agent loop in `agent.zig` implements **multi‑round tool calling** with a limit of `MAX_TOOL_ROUNDS = 8`.  It builds a system prompt, sends the user’s message to the provider, parses any `tool_calls` from the JSON response, dispatches each tool, and feeds the tool outputs back into the model.  After tool use (or when no tools are called), it returns the model’s reply to the user.  This loop allows dynamic tool usage but lacks higher‑level planning or reflection.

### Tools

* `tools.zig` defines a registry of built‑in tools: `shell`, `file_read`, `file_write`, `memory_store`, `memory_recall`, `memory_forget`, `http_request` and basic Git operations.  Each tool uses a `SecurityPolicy` to validate file paths and audit every call【932555140858001†L413-L447】.  Tools for external services can be added at runtime via the MCP client; discovered tools are exposed as `servername__toolname` and executed through `toolMcpProxy`【932555140858001†L413-L447】.

### Memory

* `memory.zig` implements a **simple key‑value memory backend** that stores each memory entry as a markdown file under `~/.bareclaw/workspace/memory`.  It supports `store`, `recall` (prefix search) and `forget`.  There is no semantic indexing or summarisation; recall is based on string prefix matching.

### Channels and I/O

* `channels.zig` provides CLI (single‑turn and loop), Discord (via the WebSocket gateway) and Telegram (HTTP long‑polling) channels.  Each channel builds an `AgentStack` (provider, memory backend, security policy and tool registry) using `buildStack()` and handles the respective protocol.  The Discord and Telegram channels integrate with environment variables for tokens and support MCP tool discovery【644316775468742†L25-L76】.【644316775468742†L134-L136】

### MCP Client/Server

* `mcp_client.zig` implements a **generic JSON‑RPC 2.0 client** that can spawn any MCP server as a subprocess, perform the handshake, discover tools via `tools/list` and call them via `tools/call`【44332349406240†L151-L165】.  A session pool caches connections across tool calls.  The repository also contains a Python MCP server (`mcp/server.py`) which wraps the BearClaw CLI and exposes build/test/run tools for agent‑driven development【212877492789752†L84-L99】.

### Security

* `security.zig` defines a **deny‑by‑default security policy**.  It restricts file access to the workspace directory, blocks dangerous shell commands (`rm`, `dd`, etc.), and logs every tool invocation to an audit log【932555140858001†L413-L447】.

### Cron and Gateway

* `cron.zig` implements a simple TSV‑backed scheduler for tasks with fields `id`, `cron_expr`, `command`, `enabled`, `last_run`.  It currently ignores actual cron expressions and runs tasks when invoked via `bareclaw cron`.  `gateway.zig` exposes a minimal HTTP endpoint for `/health` and `/webhook`【141943013744861†L14-L35】.  `daemon.zig` starts the gateway and cron runner【953655092726226†L4-L9】.


## Identified Limitations

1. **Lack of higher‑order planning:**  The agent loop dispatches tools but lacks a planner that decomposes tasks into subtasks or reflects on outcomes.  There is no mechanism for the agent to maintain a multi‑step plan across tool rounds or sessions.

2. **Shallow memory:**  Memory is simple key‑value storage.  There is no summarisation of conversations, no semantic search, and no long‑term storage of user preferences or task history beyond explicit `memory_store()` calls.

3. **No learning from user behaviour:**  The agent does not build a model of the user’s goals or preferences.  Every session starts with a generic system prompt and no persistent profile.

4. **Cron scheduler is incomplete:**  Cron entries ignore the schedule expression; tasks run only when `bareclaw cron` is manually invoked.  There is no persistent task management or time‑based automation beyond this.

5. **Limited tooling for introspection:**  While the MCP server exposes `build()`, `run_tests()` and other development tasks, there are no tools to introspect agent reasoning, memory usage or task performance.

6. **No built‑in personality/soul:**  The agent’s “character” is defined only by the system prompt; there is no mechanism for customising tone, persistence of traits or social behaviours.


## Enhancement Plan

To evolve BearClaw into a **lightweight sub‑agent system capable of critical thinking, task completion and learning**, we propose the following plan.  Each suggestion includes implementation ideas consistent with the repository’s constraints (Zig stdlib, no external dependencies) and the development guidelines laid out in `CLAUDE.md`.

### 1. Introduce a Planner/Reflector Module

* **Purpose:** enable the agent to break down a high‑level goal into a sequence of tool calls and to reflect on outcomes.
* **Implementation:**
  - Add a `planner.zig` module implementing a new `planAndExecute()` function.  The function would take the user’s goal and the tool registry, ask the provider to produce a structured plan (e.g., a JSON list of steps with tool names and arguments), and then execute each step via the existing tool dispatch.  After each step, results are fed back into the model with a prompt like “Here is the result. Do we continue or adjust the plan?” until the plan completes or a maximum depth is reached.
  - To encourage critical thinking, set the system prompt to instruct the model to **think step‑by‑step** and to check its work before finalising.  Use the multi‑round mechanism already in `agent.zig` to iterate.
  - The planner can be exposed as a new tool (e.g., `planner_execute`) so the user or an external agent can ask BearClaw to plan a task.  This keeps the core agent loop simple and avoids recursive loops.

### 2. Enhance Memory with Contextual and Semantic Recall

* **Conversation transcript storage:** after each agent run, automatically store the user input, model reply and tool results under a timestamped key in memory (e.g., `session/2026‑02‑17T15:04`).  Provide a tool `memory_summarise()` that reads a transcript and summarises it using the provider, then stores the summary.  This allows later recall of past interactions.
* **User profile:** create a `profile.md` file in the workspace that stores key/value preferences (e.g., preferred trading strategy, risk tolerance, favourite platforms).  Provide tools `profile_get()` and `profile_set()` that read/write this file.  When building prompts, load the profile and incorporate relevant preferences.
* **Semantic search:** implement a simple vector‑like search by computing **term frequency–inverse document frequency (TF‑IDF)** vectors for each memory entry and using cosine similarity.  Zig’s standard library offers basic math and string utilities; implement a small TF‑IDF module without external dependencies.  Provide `memory_search(query)` that ranks stored entries by similarity to the query and returns the top N keys.  If external embeddings become acceptable in the future, the provider could be queried for embeddings via an API, but TF‑IDF keeps the system self‑contained.

### 3. Persistent Task Manager

* Extend `cron.zig` into a **task manager** module.  Rather than ignoring cron expressions, parse them (start with a minimal parser supporting `*/n`, `*` and specific values).  Allow tasks to be scheduled at defined intervals and automatically run them via the daemon.
* Add fields `status`, `last_result` and `next_run` to the cron TSV file.  Provide tools `task_add(expr, prompt)`, `task_list()`, `task_pause(id)`, `task_resume(id)` and `task_remove(id)`.  Each task stores the prompt (or tool call) it should execute; when the daemon runs, it calls `planAndExecute()` on the prompt and stores the result.  This gives the agent the ability to “spend the time necessary” to complete recurring duties.

### 4. Improve Personality and “Soul”

* **System prompt templates:** move the system prompt into `config.toml` or a file in the workspace so users can customise the agent’s tone (e.g., empathetic, formal, playful).  Provide `config set system_prompt` via the MCP to adjust it.
* **Adaptive tone:** when storing user profile information, include a preferred communication style.  When building the system prompt, combine the base template with the user’s style.  This helps the agent feel more personalised.
* **Reflective summaries:** after completing a task via the planner, call the provider with a prompt like “Reflect on the previous actions. What went well, what could be improved?” and store the reflection.  Incorporate these reflections when planning future tasks, giving the impression of introspective learning.

### 5. Expand Tooling for Introspection and Debugging

* Add a tool `agent_status()` that returns internal state: number of memory entries, loaded tools, current provider and model, last task run and its outcome.  This helps monitor agent health without diving into log files.
* Provide `audit_log_read(n)` to read the last `n` audit entries.  This surfaces what the agent did and aids debugging.
* Include `memory_list_keys()` and `memory_delete_prefix(prefix)` to manage memory entries.

### 6. Integrate External MCP Services Smoothly

* **AutoTrader integration:** since you already have a custom MCP server for AutoTrader, ensure its tools follow the naming convention `autotrader__toolname` so the agent can call them without ambiguity【932555140858001†L413-L447】.  Consider adding planning templates specific to trading (e.g., “analyse market trend”, “execute trade with risk management”) and storing trading results in memory.
* **Graceful degradation:** if a provider fails (e.g., no Claude tokens), fallback to another provider or echo mode.  The Router already supports fallback; ensure your config lists multiple providers.

### 7. Harden Security and Reliability

* Review the **shell command blocklist** and file path policy.  When adding new tools (especially around planning and memory), always call `policy.auditLog()` and `policy.allowPath()`【932555140858001†L413-L447】.
* Implement timeouts in the planner so a tool that hangs or a provider call that blocks does not stall the entire agent.  Use Zig’s `std.posix.poll` or `std.time.sleep` similar to the Discord gateway’s use of timeouts【644316775468742†L236-L324】.
* Add unit tests for the new planner, memory search and task manager.  Use the existing MCP tools (`build()`, `run_tests()`, `run_smoke_tests()`) to validate functionality【212877492789752†L223-L244】.

### 8. Development Workflow

* Follow the guidelines in `CLAUDE.md`: read existing modules before changing them, keep changes focused, run `zig build` and `zig build test`, and update documentation accordingly.  Use the MCP test tools (`run_smoke_tests()`, `run_integration_test_discord()`) after altering channels or tasks【974495619203277†L178-L204】.
* When adding significant features (planner, memory search, task manager), update the MCP server to expose new development tools so agents can test and modify these features at runtime.


## Conclusion

BearClaw already provides a solid foundation for a lightweight, extensible agent runtime.  By adding a planner/reflector module, enhancing memory with contextual storage and semantic recall, introducing a persistent task manager, personalising the system prompt, improving introspection tools, and hardening reliability, you can give your sub‑agent the **critical thinking, persistence and “soul”** you envisioned.  All proposed enhancements respect the zero‑dependency constraint and leverage existing architecture patterns, ensuring BearClaw remains portable and maintainable.
