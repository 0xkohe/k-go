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


``` sh
ex: kompile main.k  --verbose --enable-llvm-debug --backend llvm
llvm-kompile /app/go/main-kompiled/definition.kore /app/go/main-kompiled/dt main -g -O1 -o /app/go/main-kompiled/interpreter -- -g

krun -cPGM=0 --debugger
krun codes/code-channel-lookup --debugger

kompile lesson-19-a.k  && krun code.txt
docker compose up -d && docker compose exec k bash
docker compose exec k bash -c "cd go && kompile main.k"
docker compose exec k bash -c "cd go && krun code --definition main-kompiled/"
```