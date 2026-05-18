# Tools

`Sylvia` intentionally restricts its toolkit to prevent model confusion and enhance reliability.

1. **`list_files`**: Navigates directories and reads folder structures securely.
2. **`read_file`**: Reads files with auto-injected line numbers for precise edits. Large files are safely truncated to fit within context limits.
3. **`create_file`**: Automates file scaffolding. 
4. **`replace_lines`**: Context-aware line replacement. Generates a visual diff for user approval.
5. **`search_code`**: Fast codebase searching.
6. **`run_shell`**: Executes sandboxed shell commands.

## Mutation Safety & `.bak` File Generation
For all destructive actions (`replace_lines`, `create_file`, etc.), Sylvia enforces strict Blast-Radius safety:

- **Approval Gates:** The terminal pauses for a `[y/N]` human approval.
- **Backup Generation:** Before writing over a file, Sylvia automatically creates a `.bak` copy of the original file, allowing you to instantly revert any erroneous LLM actions.