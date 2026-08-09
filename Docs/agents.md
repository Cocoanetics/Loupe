# Giving Loupe to agents

Loupe's whole reason to exist is that an agent fixing a UI bug can show its work.
This is how to wire it in.

## Any ACP agent (acpx, SwiftACP)

`acpx` forwards MCP servers into the ACP handshake, so the agent gets Loupe's
tools alongside whatever else it has. Configure it in `~/.acpx/config.json`
(global) or `<cwd>/.acpxrc.json` (per project — note the project file *replaces*
the global list rather than merging):

```json
{
  "mcpServers": [
    { "name": "loupe", "command": "/usr/local/bin/loupe", "args": ["mcp"] }
  ]
}
```

Two gotchas that cost real time:

- The key is **undocumented** in acpx's README and `acpx config show` does not
  print it. Verify it actually took effect by inspecting the outbound
  `session/new` with `--format json --verbose`.
- The default permission mode is `approve-reads`, and a screenshot tool does not
  infer as a read. In a non-TTY context that means it is **denied**, silently
  from the agent's point of view. Run with `--approve-all`, or scope it:
  `--permission-policy '{"autoApprove":["loupe_capture","loupe_describe","loupe_before","loupe_after"]}'`.

The Swift `acpx` clone currently parses `mcpServers` but never forwards it
([SwiftACP#16](https://github.com/Cocoanetics/SwiftACP/issues/16)); use the npm
`acpx` until that lands.

## A host that builds its server list in code

Some agent hosts assemble their MCP servers programmatically rather than reading
a config file. There the wiring is a few lines wherever that list is built:

```swift
var servers: [MCPServerSpec] = [ /* whatever you already start */ ]

// Visual proof only makes sense for runs that can change something and are
// working on UI. Keep tool inventories small for everyone else.
if permissionsAllowEditing, task.touchesUI {
    servers.append(.stdio(StdioMCPServer(name: "loupe", command: loupePath, args: ["mcp"])))
}
return servers
```

Two things worth copying regardless of host. Gate on whether the run can
actually change something *and* touches UI — a read-only or non-visual task
gains nothing from the tools and pays for them in context. And resolve the
binary explicitly (a bundled auxiliary executable, then an environment override,
then a path relative to your own executable) rather than relying on `$PATH`,
which a daemon launched by the system usually does not have.

## Claude Code

```bash
claude mcp add loupe -- /usr/local/bin/loupe mcp
```

## The prompt that makes it work

Tool availability is not enough — the agent has to capture the "before" *before*
it starts editing, and that ordering has to be stated. Something like:

> If this issue affects the UI, capture visual proof.
>
> 1. **Before touching any code**, get the unmodified app into the state that
>    shows the problem and run `loupe_before` with the issue number as the
>    session name. If the before state is unreachable — it does not build, or it
>    crashes before you can navigate there — skip it and say so in your comment.
>    Never fabricate a before image.
> 2. Make the fix. Rebuild. Relaunch, so you are looking at the new build and not
>    the old process.
> 3. Reach the *same* state the same way and call `loupe_after` with the same
>    session name.
> 4. Attach the returned proof image to the issue or merge request, and say in
>    one line what the reader should look at.
>
> If `loupe_after` warns that nothing changed, do not post it. That almost always
> means you are looking at the old build.

## Determinism checklist

False diffs destroy trust in the proof faster than missing diffs. Before a
comparison:

- **Simulator**: `loupe_sim_status_bar` first. The clock alone guarantees a diff.
- **Web**: use a fixed `viewport`; autoplay is already blocked by default.
- **Mac**: capture the same window (`mac:App#N`), and do not resize it between
  the two shots.
- Reach the state the same way both times. A deep link is more reproducible than
  a sequence of clicks.
