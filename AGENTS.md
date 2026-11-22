# vgraph-mcp

The MCP servers around the VGraph engine: `vgraph-mcp` (stdio), `vgraph-mcp-http`
(Cloud Run, `mcp.vithanco.com`) and the npm host `@vithanco/vgraph-mcp`, which runs
the engine as WebAssembly. No graph logic lives here.

This repository is always checked out inside a VGraph checkout, as
`VGraph/vgraph-mcp`, and builds against it as `..`. VGraph's `AGENTS.md` holds
the conventions (tests first, minimal docs, typed throws, functional style) and
they apply here; read it first. Why the split: VGraph's ADR 0040.

- Swift servers: `Sources/`, tests in `Tests/`. They are drivers: they reach
  adapters through VGraph's `App` composition and never import `VGraphSVG`,
  `VGLanguage` or `VGraphvizLib` (`Tests/RepositoryTests/DriverImportTests.swift`).
  They sit outside the wasm graph, so Foundation and key paths are fine.
- npm host: `src/`, tests in `test/`. `tools.json` is generated from the Swift
  server by `just regen`; never edit it by hand.
- The hosted endpoint is open to anyone: every input is bounded before layout
  (`MCPLimits`, `docs/mcp-hardening.md`).

`just` lists the recipes; `just test` before a pull request. Issue and pull
request descriptions are about two lines; ask before writing more.
