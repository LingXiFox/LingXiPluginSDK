# LingXiPluginSDK

Official Swift SDK for building **out-of-process** LingXiAgent plugins.

MIT · Swift Package Manager · Foundation only

The SDK does not contain LingXiAgent Core. A plugin is its own executable that
talks to a running LingXiAgent over the public **LingXi Plugin IPC** — one JSON
object per line on stdin/stdout. You do not link the agent, its session store,
its permission engine or its provider runtime, and you cannot break a user's
session by returning the wrong value: you are in another process.

```text
Your plugin binary  --(JSON Lines IPC over stdin/stdout)-->  LingXiAgent Core
     ^                                                          |
     └── LingXiPluginSDK: protocols, DTOs, IPC driver ──────────┘
```

## What belongs here, and what does not

| In this SDK | Not in this SDK (lives in LingXiAgent) |
| --- | --- |
| `LingXiPlugin` entry protocol | Tool execution loop, agent runtime |
| `PluginManifest`, `PluginCapability` | `PermissionEngine` decisions |
| `PluginTool` / `PluginCommand` / hooks | Session store, transcripts |
| `PluginContext`, `PluginInfoHub`, `PluginStorage`, `PluginLogger` | P-Core / E-Core implementation |
| `PluginIPCRequest` / `PluginIPCResponse` / `PluginDriver` | Provider clients, streaming, MCP |

## Installation

```swift
// Package.swift
dependencies: [
    .package(
        url: "https://github.com/LingXiFox/LingXiPluginSDK.git",
        from: "0.1.0"
    )
]
```

```swift
.executableTarget(
    name: "MyPlugin",
    dependencies: [
        .product(
            name: "LingXiPluginSDK",
            package: "LingXiPluginSDK"
        )
    ]
)
```

## Five-minute quick start

**1. Declare the dependency** — the block above.

**2. Write the plugin** (`Sources/MyPlugin/main.swift`):

```swift
import Foundation
import LingXiPluginSDK

@main
struct MyPlugin: LingXiPlugin {
    init() {}

    var manifest: PluginManifest {
        PluginManifest(
            id: "com.example.my-plugin",
            name: "My Plugin",
            version: "0.1.0",
            description: "Example LingXiAgent plugin"
        )
    }

    func activate(context: PluginContext) async throws {
        context.logger.info("Plugin activated")
    }
}
```

Registering behaviour is done in `activate`:

```swift
func activate(context: PluginContext) async throws {
    context.registerTool(EchoTool())
    context.registerCommand(StatusCommand())
    context.on(.sessionStart) { payload in
        context.logger.info("session started: \(payload.subjectID)")
    }
}

struct EchoTool: PluginTool {
    var name: String { "echo" }
    var description: String { "Echoes its argument back." }
    func execute(arguments: String, context: ToolExecutionContext) async throws -> String {
        arguments
    }
}

struct StatusCommand: PluginCommand {
    var name: String { "status" }
    var description: String { "Reports what the host published." }
    func execute(args: [String], context: CommandExecutionContext) async throws -> PluginCommandResult {
        guard let workspace = try? await context.info.getWorkspaceInfo() else {
            return .message("运行时信息尚未由宿主推送", presentation: .inline)
        }
        return .message("工作区 \(workspace.rootPath)（\(workspace.currentGitBranch ?? "非 Git")）")
    }
}
```

**3. Build and install it:**

```bash
swift build -c release
mkdir -p ~/.lingxiagent/plugins
cp .build/release/my-plugin ~/.lingxiagent/plugins/
```

A plugin is discovered at startup from `~/.lingxiagent/plugins` and, for a
project, `<project>/.lingxi/plugins`. The file must be an executable binary for
the platform LingXiAgent runs on: on macOS and Linux the name is the file name,
on Windows build with `swift build -c release` and copy `my-plugin.exe`.

## Lifecycle

```text
Core spawns the plugin process
  ↓  host.snapshot        Core pushes authoritative runtime state
  ↓  plugin.initialize    handshake: manifest, ipcVersion, tools, commands, hooks
  ↓  activate(context:)   your registrations become visible to the host
  …  tool.execute / command.execute / hook.emit   (each preceded by a snapshot refresh)
  ↓  stdin closes (EOF)   deactivate(), process exits
```

`PluginDriver.main()` (available through `@main` on your type) runs that loop;
you do not implement framing, timeouts or the reader yourself.

## Manifest and capabilities

`PluginManifest` is identity plus a permission request:

```swift
PluginManifest(
    id: "com.example.my-plugin",
    name: "My Plugin",
    version: "0.1.0",
    description: "…",
    capabilities: [.projectRead, .networkAccess]
)
```

| Capability | Meaning |
| --- | --- |
| `projectRead` | read inside the workspace |
| `projectWrite` | write inside the workspace |
| `processExecution` | spawn processes |
| `networkAccess` | outbound network |

Capabilities are an **admission request**, checked by the host before your
plugin is used — see Security model below.

## Runtime info: read-only, host-published, and honest about gaps

`context.info` is a `PluginInfoHub`. Every value in it was produced by
LingXiAgent Core and pushed to your process; the SDK measures nothing,
estimates nothing and defaults nothing.

```swift
let workspace = try await context.info.getWorkspaceInfo()
let pe = try await context.info.getPECoreInfo()          // P-Core / E-Core counters
let ctx = try await context.info.getContextState()       // session-level state
let perf = try await context.info.getPerformanceInfo()    // may be absent
```

Anything Core has not published throws `PluginInfoUnavailable(field:)` rather
than returning `idle`, `unknown` or `0`. That is deliberate: a plugin must be
able to tell "the host is idle" from "the host did not tell me".

Two notes on meaning, because P-Core and E-Core are easy to conflate:

- **P-Core** is what stays inside the model request (stable prefix + growing
  context + E-Core index projection). Its eviction is decided by a P-side
  retention policy.
- **E-Core** is the store of full objects that were paged out, with exact
  restore and semantic recall. Its heat serves recall, caching and
  observability — it does **not** drive P-Core eviction.

## Plugin IPC

One JSON object per line, request then response, newline-delimited. It is
**not** JSON-RPC 2.0: the wire carries no `jsonrpc` field, and there are no
batches or notifications.

| Method | Direction | Payload |
| --- | --- | --- |
| `host.snapshot` | Core → plugin | `PluginRuntimeSnapshot` |
| `plugin.initialize` | Core → plugin | `PluginInitializeParams` → `PluginHandshakeResult` |
| `tool.execute` | Core → plugin | `PluginToolCallParams` → `String` |
| `command.execute` | Core → plugin | `PluginCommandCallParams` → `PluginCommandCallResult` |
| `hook.emit` | Core → plugin | `PluginHookPayload` → empty |

`PluginIPC.Method` is the single source of these names; a document cannot invent
another one. Errors come back as a response with `error` set, and the host turns
an unknown method, a missing parameter block or a malformed payload into a
failed call — never a crash of the plugin loop.

### Versioning

| | |
| --- | --- |
| This SDK | `0.1.0` |
| Plugin IPC version | `1` (`PluginIPC.currentVersion`) |
| Swift tools version | 6.0 |
| Minimum LingXiAgent for tools / commands / hooks | 1.1.0 |
| Minimum LingXiAgent for `context.info` data | a build that pushes `host.snapshot` (post-1.1.0) |

Compatibility is negotiated by `ipcVersion`, not by comparing version strings.
If host and plugin share no supported version, the handshake fails loudly at
load time. Against a host that predates `host.snapshot`, your tools and commands
still work and `context.info` reports `PluginInfoUnavailable` — again, no
invented numbers. `PluginManifest.minimumCoreVersion` is a human-readable hint,
never a wire check.

## Security model, stated accurately

What the host does today:

| Layer | Guarantee |
| --- | --- |
| Process isolation | your plugin is a separate `Process`, not injected code |
| Credential isolation | the child gets a sanitized environment: no provider keys, no vault passphrase |
| Capability admission | declared `PluginManifest.capabilities` are checked before use, and a denial terminates the plugin |
| IPC boundary | typed, line-delimited requests and responses |
| Watchdog | an unanswered call times out and the process is terminated |

What it does **not** claim: there is no OS-level syscall or filesystem sandbox
here. A plugin process can still attempt `FileManager` or network calls with the
privileges of the user running LingXiAgent; declared capabilities are an
admission policy enforced by the host, not a kernel boundary. Documentation that
promised otherwise would be selling a guarantee the runtime does not implement.

## Plugin storage

```swift
try await context.storage.set(key: "seen", value: "yes")
let seen = try await context.storage.get(key: "seen")
```

`PluginStorage` is an SDK-managed, plugin-local key/value directory under
`~/.lingxiagent/plugin-data/<plugin-id>`. It is namespacing and convenience,
not a sandbox: values are plain files owned by your plugin.

## Troubleshooting

| Symptom | What is actually happening |
| --- | --- |
| plugin never appears | binary is not in `~/.lingxiagent/plugins` (or `.lingxi/plugins`), or is not executable |
| `Plugin initialization capability request: …` denied | the host's permission policy rejected a declared capability; the process is terminated at handshake |
| `Unsupported host IPC version N` | host and plugin share no `PluginIPC.supportedVersions`; rebuild against the current SDK or update the host |
| `Plugin 'x' speaks LingXi Plugin IPC vN` | same mismatch, detected on the host side at load |
| `Tool 'x' not found in plugin` | the tool name you exposed differs from the one Core routed to; names are exact |
| `Command 'x' not found in plugin` | same, for commands (aliases are matched too) |
| `Plugin IPC call timed out after 3.0s` | your handler did not answer in time; move long work off the request path |
| `Plugin process is not running` | the process exited or was terminated; check stderr and `deactivate()` |
| `Plugin runtime info unavailable: peCore (no snapshot received)` | the host never pushed a snapshot: older host, or info requested before `host.snapshot` |

## Tests

```bash
swift build
swift test
```

`PluginIPCContractTests` pins the wire format, `PluginInfoHubTests` pins the
authoritative-snapshot semantics, and `DocumentationExampleCompileTests`
compiles the snippets on this page so the documentation cannot drift ahead of
the code.

## License

MIT — see [LICENSE](LICENSE). Commercial use, closed-source plugins,
modification and redistribution in source or binary form are all permitted; the
only obligation is keeping the copyright and permission notice.
