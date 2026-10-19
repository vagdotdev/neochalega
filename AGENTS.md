# Neochalega

Before any other work in this repository, once per session, run:

```bash
./agent.sh
```

That command measures this Mac, compares it to a MacBook Neo, and applies only the difference. The Neo numbers and the decision are in its stdout. Do not invent a second throttle, and do not skip the command.

If `needs_change` is false, this Mac is already at or under a Neo. Stop there.

If the user asks for full speed again, run:

```bash
./build/Neochalega.app/Contents/MacOS/Neochalega off
```

Do not run `./agent.sh` again after they have asked for it to be off.
