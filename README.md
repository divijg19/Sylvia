# `Sylvia`

[![Written in Zig](https://img.shields.io/badge/Written_in-Zig-F7A41D?style=for-the-badge&logo=zig)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)](LICENSE)
[![No Dependencies](https://img.shields.io/badge/Dependencies-0-success?style=for-the-badge)]()

A hyper-lightweight, zero-dependency, shell-native cognition runtime for Unix systems. Written entirely in Zig.

## Quickstart

Instantly install the latest pre-compiled release for your system:

```bash
curl -fsSL https://raw.githubusercontent.com/divijg19/Sylvia/main/installer.sh | bash
```

## Features

- **Zero-Dependency Native Binary**: Just drop the executable into your `PATH`. No Python environments, no `npm install`.
- **True SSE Streaming**: Real-time token rendering directly in your terminal.
- **Unix Composability**: Built to naturally pipe stdin/stdout standard data streams (`git diff | sylvia "review"`).
- **Blast-Radius Safety**: Automated operations pause for human `[y/N]` approval on destructive file changes.

## Documentation

Dive deep into `Sylvia`'s setup, usage, internal architecture, and tooling by visiting our official docs:

- 📖 [Usage & Configuration](docs/USAGE.md)
- 🧠 [Architecture & How It Works](docs/ARCHITECTURE.md)
- 🛠️ [Built-in Tools & Safety](docs/TOOLS.md)
- 💻 [Development & Contributing](docs/DEVELOPMENT.md)

---

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
