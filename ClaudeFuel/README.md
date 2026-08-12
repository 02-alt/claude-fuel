# Claude Token Fuel ⛽

A skeuomorphic macOS **menu-bar app** that shows your Claude token consumption as a
retro fuel gauge — a silver machined-metal "beeper" with a pixelated dot-matrix LCD.

![preview](../.context/dev_silver.png)

## What it does

- **Menu-bar item** with a live **countdown timer** (until your usage window refuels)
  and a **color indicator** (green / amber / red) for how much fuel is left.
- Click the menu-bar icon to open the **device popover**: a fuel gauge sweeping
  **E → F**, the big **% remaining**, `used / tank` tokens, your **plan + tank size**,
  a segmented fuel bar, and the reset countdown.
- Three physical buttons:
  - **Stats** — usage breakdown (window, today, per-model, lifetime).
  - **Settings** — data-source connection, plan/tank budget, and theme.
  - **Mini** — pops the gauge out into a floating, always-on-top window you can
    park in a screen corner.
- Themes: **Silver** (machined metal), **Graphite** (dark, backlit green LCD),
  **Amber CRT**.

## Data source

Reads your **local Claude Code usage** from `~/.claude/projects/**/*.jsonl` — the same
transcripts the CLI writes. No login or API key. Tokens are grouped into rolling
windows (default 5 h, ccusage-style "blocks"); the active window is your "tank".

> Subscription plans don't publish a token allowance, so the **tank size is a value you
> set** in Settings (per plan). The meter fills your *real* consumed tokens against it.
> Cache-read tokens are excluded by default (they're the cheap part); toggle in Settings.

## Build & run

```bash
cd ClaudeFuel
./build_app.sh                       # builds ClaudeFuel.app (menu-bar agent)
open ./ClaudeFuel.app                # run it
cp -R ./ClaudeFuel.app /Applications # optional install
```

Dev helpers:

```bash
swift run ClaudeFuel --dump                          # print parsed usage
swift run ClaudeFuel --render out.png --theme silver --frac 0.6   # render a preview
```

To launch automatically at login: System Settings → General → Login Items → add
`ClaudeFuel.app`.
