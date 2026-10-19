# Neochalega

Agents: follow [AGENTS.md](AGENTS.md) before anything else. The first command is `./agent.sh`.

A menu bar app that makes this Mac stand in for a [MacBook Neo](https://www.apple.com/macbook-neo/specs/) while you try a real workload.

The Neo is an Apple A18 Pro: 6 CPU cores and 8 GB of memory. Its single core is about as fast as a recent Mac performance core. Neochalega locks away the extra memory and, while it is on, clamps parallel work to about 6 cores. One light task is left alone.

Click the menu bar mark. The panel opens under it. Press the round button. Press it again, or quit, and the lock is released and the burn threads stop before the app is done. The throttle lives in this process only. It does not keep running after quit, and it does not ease off while the button still says on.

GPU cores and memory bandwidth are not changed. Games will still feel faster than a real Neo.

`./agent.sh` builds the app if needed, prints the comparison, and turns the throttle on. `Neochalega off` releases it. The round button in the menu bar does the same thing.

## Build

```bash
git clone https://github.com/vagdotdev/neochalega.git
cd neochalega
./build.sh --install
open ~/Applications/Neochalega.app
```

`./build.sh` alone writes `build/Neochalega.app`.

## License

MIT
