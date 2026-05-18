# Architecture

## 🧠 Core Philosophy
Most agentic frameworks are built in Python or Node.js, rely on massive dependency trees, and suffer from out-of-memory context bloat when run locally. `Sylvia` is built differently:

1. **Small > Smart:** Prefers predictable behavior and tight execution loops over sprawling autonomous "multi-agent" spirals.
2. **Control > Capability:** Hard limits everywhere. Max execution steps, truncated log outputs, and rolling context windows keep CPU inference blazing fast.
3. **The Blast Radius (UX First):** Safe tools run automatically. Destructive tools (`run_shell`, `replace_lines`, `create_file`) pause execution, render a visual diff, and require `[y/N]` human approval.
4. **Forgiving by Design:** Small local models (7B/14B) fail at strict JSON schemas. `Sylvia` uses a highly optimized, fault-tolerant Markdown-block parser for tool execution.

## ⚙️ How It Works

`Sylvia` operates on a strict **Two-Phase ReAct Loop**:

1. **Phase 1: Planning.** The task and directory structure are sent to the model to generate a high-level plan.
2. **Phase 2: Execution.** A constrained `while` loop (max steps configured) spins up. For every turn:
   - An `ArenaAllocator` isolates memory to guarantee **Memory Determinism**.
   - The LLM streams a `THOUGHT` and a markdown-fenced `ACTION`.
   - The custom Zig state-machine parses the action.
   - If the action alters files or runs bash, the terminal pauses for `[y/N]` approval.
   - Output is captured, truncated, and appended to the context.
   - The `ArenaAllocator` is destroyed, preventing memory leaks, and the loop repeats.

### Anti-Spiral Wyhash
To prevent infinite loops of repeating the same actions or errors, Sylvia implements an Anti-Spiral mechanism utilizing Wyhash to monitor action history and intelligently block looping behaviors.