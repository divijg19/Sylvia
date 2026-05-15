# `Sylvia`

[![Written in Zig](https://img.shields.io/badge/Written_in-Zig-F7A41D?style=for-the-badge&logo=zig)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](LICENSE)
[![No Dependencies](https://img.shields.io/badge/Dependencies-0-success?style=for-the-badge)]()

`Sylvia` is a lightweight, zero-dependency, local-first coding agent runtime written entirely in Zig. It combines the rapid, bounded execution of local LLMs (like Qwen2.5-Coder or Llama-3) with a premium, terminal-native UX inspired by Claude Code.

By leveraging Zig’s explicit memory management, `Sylvia` eliminates context bloat, guarantees constant memory usage, and ships as a single `< 2MB` executable. It is designed to be a deterministic, locally-hosted tool for guided codebase manipulation.

---

## 🧠 Core Philosophy

Most agentic frameworks are built in Python or Node.js, rely on massive dependency trees, and suffer from out-of-memory context bloat when run locally. `Sylvia` is built differently:

1. **Small > Smart:** Prefers predictable behavior and tight execution loops over sprawling autonomous "multi-agent" spirals.
2. **Control > Capability:** Hard limits everywhere. Max execution steps, truncated log outputs, and rolling context windows keep CPU inference blazing fast.
3. **The Blast Radius (UX First):** Safe tools run automatically. Destructive tools (`run_shell`, `replace_in_file`) pause execution, render a visual diff, and require `[y/N]` human approval.
4. **Forgiving by Design:** Small local models (7B/14B) fail at strict JSON schemas. `Sylvia` uses a highly optimized, fault-tolerant Markdown-block parser for tool execution.

---

## ✨ Features

- **Zero-Dependency Native Binary:** Just drop the executable into your `PATH`. No Python environments, no `npm install`.
- **Universal API Standard:** Natively talks to any OpenAI-compatible `/v1/chat/completions` endpoint. Seamlessly swap between Ollama, LM Studio, NVIDIA NIMs, or Groq.
- **Claude-Code Style TUI:** ANSI spinners, color-coded agent thoughts, and rich visual terminal diffs (`- red` / `+ green`).
- **Rolling Context Evictor:** Automatically prunes old thoughts/actions to maintain a perfectly flat context window size, ensuring your CPU doesn't choke on turn 15.
- **Repetition Breaker:** Automatically detects if the LLM is stuck in an execution loop and injects system interrupts to correct its course.

---

## 🛠️ Built-in Tools

`Sylvia` intentionally restricts its toolkit to prevent model confusion:

1. `list_files`: Navigates directories (ignores `.git`, `node_modules`).
2. `read_file`: Reads files with auto-injected line numbers for precise edits. Large files are safely truncated.
3. `replace_in_file`: Replaces exact strings. Generates a visual diff for user approval before writing.
4. `run_shell`: Executes sandboxed shell commands (e.g., `cargo test` or `zig build`). Prompts for user approval.
5. `search_code`: Pure Zig, cross-platform grep alternative for searching text across the codebase.

---

## 🚀 Getting Started

### Prerequisites
- [Zig](https://ziglang.org/download/) (v0.13.0 or later) to build from source.
- An OpenAI-compatible LLM endpoint (e.g.,[Ollama](https://ollama.com/) running locally).

### Installation

Clone the repository and build the release binary:

```bash
git clone https://github.com/divijg19/sylvia.git
cd sylvia
zig build -Doptimize=ReleaseFast
```

Move the compiled binary to your `PATH`:

```bash
mv zig-out/bin/sylvia /usr/local/bin/sylvia
```

---

## 💻 Usage

### Local CPU Execution (Default)
By default, `Sylvia` looks for a local Ollama instance running on port `11434`.

```bash
sylvia run "Refactor src/memory/context.zig to use an ArenaAllocator"
```

### Cloud API Execution (Blazing Fast)
Want to use open-source models but lack the hardware? Point `Sylvia` to a free provider like NVIDIA NIM, Groq, or Together AI.

```bash
# Using NVIDIA NIM for instant Qwen2.5-Coder inference
export SYLVA_URL="https://integrate.api.nvidia.com/v1"
export SYLVA_API_KEY="nvapi-YOUR-KEY"
export SYLVA_MODEL="qwen2.5-coder-32b-instruct"

sylvia run "Write a comprehensive test suite for the HTTP parser"
```

---

## ⚙️ How It Works (Architecture)

`Sylvia` operates on a strict **Two-Phase ReAct Loop**:

1. **Phase 1: Planning.** The task and directory structure are sent to the model to generate a 3-step high-level plan.
2. **Phase 2: Execution.** A constrained `while` loop (max 15 steps) spins up. For every turn:
   - An `ArenaAllocator` isolates memory.
   - The LLM streams a `THOUGHT` and a markdown-fenced `ACTION`.
   - The custom Zig state-machine parses the action.
   - If the action alters files or runs bash, the terminal pauses for `[y/N]` approval.
   - Output is captured, truncated to 1000 characters, and appended to the context.
   - The `ArenaAllocator` is destroyed, preventing memory leaks, and the loop repeats.

---

## 🔧 Configuration Options

You can configure `Sylvia` using environment variables or CLI flags:

| Environment Variable | CLI Flag | Default Value | Description |
| :--- | :--- | :--- | :--- |
| `SYLVA_URL` | `--url` | `http://localhost:11434/v1` | Base URL for the OpenAI-compatible API. |
| `SYLVA_API_KEY` | `--key` | `null` | API Key (if required by provider). |
| `SYLVA_MODEL` | `--model` | `qwen2.5-coder:7b` | The model name to request. |
| `SYLVA_MAX_STEPS` | `--max-steps` | `15` | Hard limit on the agent loop. |

---

## 🤝 Contributing

`Sylvia` is built with minimalism in mind. We welcome PRs that fix bugs, improve parser reliability, or enhance terminal UI rendering.

**Please note:** We actively reject PRs that add complex multi-agent frameworks, Vector DB integrations, or heavy standard library dependencies. Keep it minimal. Keep it Zig.

1. Fork the repo.
2. Create a new branch (`git checkout -b feature/better-diffs`).
3. Commit your changes (`git commit -am 'Add better diff coloring'`).
4. Push to the branch (`git push origin feature/better-diffs`).
5. Open a Pull Request.

---

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
