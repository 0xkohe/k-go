# k-framework

K Framework experiments and the Go semantics live in `src/go/`. The repo already contains Docker tooling plus a collection of runnable Go snippets that exercise the semantics.

## Quick Start (Go semantics)

```bash
# Start the toolchain container
docker compose up -d && docker compose exec k bash

# Inside the container (/app/go)
kompile main.k --backend llvm
krun codes/code --definition main-kompiled/
```

Notes:
- Sample programs now live under `src/go/codes/`. Pick any file in that directory (for example `codes/code-s`) when invoking `krun`.
- Use `krun codes/<sample> --debugger` for interactive stepping.
- Clean builds by removing `main-kompiled/` before re-running `kompile`.

See `AGENTS.md` or `CLAUDE.md` for detailed contributor guidance.
