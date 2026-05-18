# Development

## Prerequisites
- [Zig](https://ziglang.org/download/) (v0.13.0 or later) to build from source.
- An OpenAI-compatible LLM endpoint (e.g., [Ollama](https://ollama.com/) running locally).

## Building from Source

Clone the repository and build the release binary:

```bash
git clone https://github.com/divijg19/sylvia.git
cd sylvia
zig build -Doptimize=ReleaseSafe
```

Move the compiled binary to your `PATH`:

```bash
mv zig-out/bin/sylvia /usr/local/bin/sylvia
```

## Testing

Run the full memory-safe test suite using Zig's native test runner:

```bash
zig build test
```

## Contributing

`Sylvia` is built with minimalism in mind. We welcome PRs that fix bugs, improve parser reliability, or enhance terminal UI rendering.

**Please note:** We actively reject PRs that add complex multi-agent frameworks, Vector DB integrations, or heavy standard library dependencies. Keep it minimal. Keep it Zig.

1. Fork the repo.
2. Create a new branch (`git checkout -b feature/better-diffs`).
3. Commit your changes (`git commit -am 'Add better diff coloring'`).
4. Push to the branch (`git push origin feature/better-diffs`).
5. Open a Pull Request.