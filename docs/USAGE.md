# Usage

`Sylvia` is built to integrate seamlessly into standard UNIX workflows.

## Default Execution
By default, `Sylvia` looks for a local Ollama instance running on port `11434`.

```bash
sylvia "Refactor src/memory/context.zig to use an ArenaAllocator"
```

## Stdin Piping
Sylvia reads from standard input naturally, allowing composable shell pipelines:
```bash
git diff | sylvia "review these changes and suggest optimizations"
```

## `@` Context Injection
Quickly append specific file contents directly into the prompt without manual copying:
```bash
sylvia "fix the error handling in this module" @src/main.zig
```

## Engine Profiles & Configuration

You can configure `Sylvia` using environment variables. Point `Sylvia` to a free provider like NVIDIA NIM, Groq, or Together AI.

```bash
# Using Groq for high-speed inference
export SYLVIA_URL="https://api.groq.com/openai/v1"
export SYLVIA_API_KEY="gsk_YOUR_KEY"
export SYLVIA_MODEL="llama-3.1-70b-versatile"

sylvia "Write a comprehensive test suite for the HTTP parser"
```

| Environment Variable | Default Value | Description |
| :--- | :--- | :--- |
| `SYLVIA_URL` | `http://localhost:11434/v1` | Base URL for the OpenAI-compatible API. |
| `SYLVIA_API_KEY` | `null` | API Key (if required by provider). |
| `SYLVIA_MODEL` | `qwen2.5-coder:7b` | The model name to request. |
| `SYLVIA_MAX_STEPS` | `15` | Hard limit on the agent loop. |