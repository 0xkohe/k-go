# Repository Guidelines

## Project Structure & Module Organization
- Root docs: `README.md`, `K_framework_documentation.md`.
- Source is mounted into containers from `src/`.
- Go semantics (K) live in `src/go/`:
  - Entry modules: `src/go/main.k` (imports `go.k`, `func.k`).
  - Example programs: `src/go/codes/` (e.g., `codes/code`, `codes/code-s`).
- Other examples/experiments in `src/other/` (e.g., Peano, Turing machine).

## Reference Documentation
- **K Framework details**: See `K_framework_documentation.md` in the root directory for comprehensive K Framework language reference, semantics, and tooling information.
- **Go language specification**: See `src/go/go_language_specification.txt` for the official Go language specification details when implementing or extending Go features.
- **Naming convention**: Always refer to the Go specification and align naming, terminology, and syntax elements as closely as possible with the official Go language specification to maintain consistency and correctness.

## Build, Test, and Development Commands
- Start dev container: `docker compose up -d --build`
- Enter container: `docker compose exec k bash`
- Compile Go semantics (inside container):
  - `cd /app/go && kompile main.k --backend llvm`
  - Produces `main-kompiled/` (clean with `rm -rf main-kompiled`).
- Run sample program (inside ` /app/go`):
  - `krun codes/code` or `krun codes/code-s`
  - Debug: `krun codes/code --debugger`

### Testing After Changes
After modifying K definitions, run the following commands from the project root:
```bash
# 1. Recompile the definitions
docker compose exec k bash -c "cd go && kompile main.k"

# 2. Run test program to verify changes
docker compose exec k bash -c "cd go && krun codes/code --definition main-kompiled/"
```

## Coding Style & Naming Conventions
- K files use 2-space indentation; no tabs.
- Module names are UPPER_SNAKE with hyphen segments (e.g., `GO-SYNTAX`).
- Keep syntax declarations, configuration, and rules grouped by concern.
- Prefer small, composable modules imported by an explicit `MAIN` module.
- Comments: `// inline` or `/* block */` with concise rationale.

## Testing Guidelines
- Use runnable examples under `src/go/codes/` as smoke tests via `krun`.
- Add new minimal programs under `src/go/codes/` to cover new features.
- For semantic properties, prefer K proofs (`kprove`) when adding formal specs; place specs alongside modules and document how to run them.

## Commit & Pull Request Guidelines
- Commit messages: short imperative summary (≤72 chars); include context in body.
- Conventional prefixes encouraged: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`.
- PRs must include: purpose, high-level changes, how to build/run, and sample inputs/outputs (e.g., `krun codes/code`). Attach screenshots or logs when helpful.

## Security & Environment
- Development runs inside `runtimeverificationinc/kframework-k` via Docker; container mounts `src` to `/app` and enables `gdb` for LLVM debugging.
- Avoid committing compiled directories (`*-kompiled/`) or local editor artifacts.
- Pin any external tool versions in Dockerfile; discuss image bumps in PRs.
