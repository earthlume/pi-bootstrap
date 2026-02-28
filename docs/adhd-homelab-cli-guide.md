# The ADHD Homelab CLI Starter Kit

> **Last verified: February 2026.** Technical claims (versions, binary availability, RAM usage) were fact-checked against current releases and community benchmarks. Corrections from that review are noted inline where applicable.

**Your dopamine-friendly terminal starts with one principle: good defaults beat infinite configurability.** Community consensus from r/ADHD, r/homelab, Hacker News, and developer blogs converges on a clear finding — ADHD brains thrive with tools that work out of the box, provide constant visual feedback, and resist the config rabbit hole. This report maps every tool, strategy, and resource-impact metric you need to build a tiered bootstrap script for Pi Zero through Pi 5, with real user testimony driving every recommendation.

The research covers 20+ CLI tools, 3 shell ecosystems, 2 multiplexers, 5 color themes, 4 dotfile managers, and dozens of community-tested patterns. Each recommendation carries a hardware tier rating: **Light** (Pi Zero/2B, <=1GB RAM) or **Full** (Pi 5, 4-16GB RAM). Where the community disagrees, both sides are presented with evidence.

---

## Why ADHD brains need a different terminal

The terminal is simultaneously the most powerful and most dangerous tool for an ADHD developer. It offers endless novelty (dopamine), deep customization (hyperfocus bait), and zero guardrails against yak-shaving. One developer with ADHD captured it perfectly: "What starts as 'quickly organizing my desk' becomes reorganizing my entire room, researching optimal storage solutions, and somehow ending up on Wikipedia reading about minimalism for two hours."

The ADHD-specific challenges this kit addresses are **working memory deficits** (forgetting commands, paths, and which Pi you're SSH'd into), **executive function struggles** (choosing what to do next, maintaining configs), **context-switching costs** (jumping between Pis loses your mental state), and **the configuration trap** (spending hours customizing instead of working). Every tool recommendation below is evaluated against these four failure modes.

**Three community-tested principles** guide the entire stack:

- **Prefer tools with sensible defaults** over infinitely configurable ones — fish over bash, Zellij over tmux, Starship over hand-rolled PS1. Each configuration surface area is a yak-shaving opportunity.
- **Maximize visual feedback** — syntax highlighting, colored output, prompt context, and MOTD dashboards provide the constant feedback loop ADHD brains crave without requiring conscious effort.
- **Automate the forgettable** — directory jumping (zoxide), command recall (fzf + autosuggestions), long-running command notifications (ntfy), and dotfile sync (chezmoi) remove tasks that depend on working memory.

---

## The shell question: zsh wins for homelab, but fish deserves consideration

The zsh-vs-fish debate generates the strongest opinions in ADHD developer communities. Fish shell is arguably the most ADHD-friendly interactive shell ever built — it ships with autosuggestions, syntax highlighting, tab completions from man pages, and a web-based config UI, all requiring zero configuration. Julia Evans (jvns.ca) captures the appeal: "My fish configuration file literally just sets some environment variables and that's it." A Lobsters commenter adds: "Fish does 80% of what everyone says they love about zsh, but learning and configuring it takes a couple hours instead of being a new full-time job."

However, **fish's non-POSIX syntax creates real friction for Pi homelab work**. You can't paste bash one-liners from Stack Overflow, Docker documentation, or Pi tutorials without mental translation. The `bass` wrapper helps but adds cognitive overhead. For someone SSH-jumping between Pis and frequently running bash-native commands, this tax compounds.

**The recommended approach: zsh with a minimal, curated plugin set** — specifically avoiding Oh My Zsh's framework overhead. Oh My Zsh accounts for ~55% of shell startup time in profiling tests and encourages the exact plugin-hoarding behavior that ADHD users should avoid. Instead, use **Antidote** as a plugin manager (simple `.zsh_plugins.txt` declarative file, supports lazy loading via `kind:defer`) with exactly these plugins:

| Plugin | ADHD Function | Priority |
|--------|--------------|----------|
| **zsh-autosuggestions** | Eliminates command recall from memory — shows gray inline suggestions from history | Essential |
| **zsh-syntax-highlighting** | Red/green feedback before hitting Enter — prevents error -> frustration cycles | Essential |
| **fzf** (+ fzf-tab) | Fuzzy-find everything: history (Ctrl+R), files (Ctrl+T), directories (Alt+C), tab completions | Essential |
| **zsh-you-should-use** | Reminds you of your own aliases — "Found existing alias for 'git status'. You should use: gs" | Highly recommended |
| **zsh-abbr** | Fish-style abbreviations that expand inline, keeping command history transparent and readable | Recommended |
| **zoxide** | Frecency-based directory jumping — `z docker` jumps to your most-visited docker path | Recommended |
| **sudo** (OMZ) | Double-tap ESC to prepend `sudo` — tiny quality-of-life win | Nice to have |

Startup time with this stack and Antidote's lazy loading: **30-80ms** on x86, proportionally slower on ARM but still sub-second even on Pi Zero. Compare Oh My Zsh defaults at 500-3000ms.

**If configuration feels genuinely overwhelming**, install fish (`apt install fish`) and stop. Use `#!/bin/bash` shebangs for scripts. This is a legitimate, community-validated strategy. Fish 4.0 (rewritten in Rust, released February 2025) is efficient on ARM.

---

## Prompt, theme, and multiplexer: the visual stack

### Starship for Pi 5, Powerlevel10k for Pi Zero

**Starship** is the recommended prompt for the Full tier. It's actively maintained (v1.24.2, January 2026), shell-agnostic (works with bash/zsh/fish), configured via a single clean TOML file, and ships pre-built ARM binaries for both **32-bit** (`arm-unknown-linux-musleabihf`, ~4.5MB) and **64-bit** (`aarch64-unknown-linux-musl`, ~4.5MB). The built-in Catppuccin preset deploys with one command: `starship preset catppuccin-mocha -o ~/.config/starship.toml`.

**Powerlevel10k** remains the better choice for constrained devices despite being on "life support" since May 2024. Its killer feature is **instant prompt** — the prompt renders in under **10ms** by caching the display before plugins load. Since P10k runs inside the shell process (no fork+exec per prompt like Starship), it eliminates the per-command overhead that matters on a single-core Pi Zero. The interactive `p10k configure` wizard produces a working config in 3 minutes with zero manual editing. The downside: it's zsh-only and won't receive new features.

For the **absolute minimum** (Pi Zero running headless with SSH), a simple PS1 with hostname color-coding costs zero resources and solves the "where am I?" problem immediately.

### Catppuccin Mocha is the theme to standardize on

Among Catppuccin, Dracula, Nord, Gruvbox, and Tokyo Night, **Catppuccin has the broadest ecosystem by a wide margin** — over **300 official ports** maintained by a dedicated GitHub organization. It covers every tool in this stack: terminal emulators (25+), tmux, Neovim, bat, btop, fzf, lazygit, Starship, and Zellij. The Mocha flavor (darkest) uses pastel colors that are "soft without being washed out, vibrant without being eye-searing" — exactly the low-stimulation-but-still-engaging balance that ADHD users report preferring. Blues and greens (prominent in Catppuccin) are associated with improved focus and reduced eye strain in color psychology research. Consistency across all tools reduces the cognitive load of context-switching between applications.

### Zellij for Pi 5, tmux for Pi Zero

This is the starkest tier split in the entire stack. **Zellij's contextual keybinding hints** in the status bar are transformative for ADHD users — you never need to memorize a shortcut because the bar updates to show available commands in each mode. One user: "From memory, I can tell you which keystrokes synchronize input across panes, even though I have literally never used that feature before." It ships productive defaults, needs no configuration, and supports session resurrection for context-switching.

But Zellij consumes **~80MB RAM** for an empty session versus tmux's **~6MB** (note: newer benchmarks under typical conditions show ~22MB vs ~12MB — the gap narrows but Zellij is still significantly heavier), its binary is **~38MB** (versus tmux's ~900KB), and critically, **it has no 32-bit ARM binary** — no armv6 or armv7 support. On Pi Zero with 512MB total RAM, Zellij would consume 16% of available memory before doing anything. tmux is the only viable option for the Light tier. Add the `tmux-which-key` plugin (press prefix + space for a command menu) to partially replicate Zellij's discoverability.

---

## Every CLI tool rated for Pi hardware

The table below covers each tool's resource footprint, ARM availability, and tier recommendation. **Go-based tools generally have better armv6 coverage** (fzf, duf, and glow ship armv6 binaries), while **Rust-based tools typically stop at armv7** — a critical distinction for Pi Zero (original).

| Tool | Replaces | Size | RAM | apt (bookworm) | armv6 binary | Light tier | Full tier |
|------|----------|------|-----|----------------|-------------|------------|-----------|
| **fzf** | history search | ~4MB | 10-30MB | Yes | Yes (official) | Install | Install |
| **zoxide** | cd/z | ~2MB | <1MB | Yes | armv7 only | Install | Install |
| **ripgrep** | grep | ~5MB | <5MB | Yes | apt only | Install | Install |
| **bat** | cat | ~6MB | ~10MB | Yes (as batcat) | apt only | Install | Install |
| **eza** | ls | ~3MB | <5MB | No (trixie+) | No | Skip | Install |
| **fd** | find | ~4MB | Yes (fd-find) | apt only | Yes | Install | Install |
| **tealdeer** | man/tldr | ~3MB | Yes | armv7 only | Yes | Install | Install |
| **duf** | df | ~4MB | Yes | Yes (official) | Yes | Install | Install |
| **delta** | diff | ~10MB | No (trixie+) | GitHub only | No | Skip | Install |
| **dust** | du | ~3MB | No | No | No | Use ncdu | Install |
| **glow** | less (md) | ~12MB | No (trixie+) | Yes (official) | Maybe | Maybe | Install |
| **btop** | htop | ~3MB | Yes | armv7 only | No | Use htop | Install |
| **lazygit** | git CLI | ~18MB | No | No | No | Skip | Install |
| **lazydocker** | docker CLI | ~18MB | No | No | No | Skip | Install |
| **ncdu** | du (interactive) | ~200KB | Yes | Yes | Yes | Install | Install |
| **htop** | top | ~300KB | Yes | Yes | Yes | Install | Install |

**Critical warning: never run `cargo install` on Pi Zero** — confirmed OOM crashes on 512MB RAM. Use pre-built binaries or cross-compile. Go tools compile more successfully on constrained hardware but still struggle on Pi Zero.

For the Light tier, the safe set is: **fzf, zoxide, ripgrep, bat, fd, tealdeer, duf, ncdu, htop** — all available via apt on Raspberry Pi OS bookworm or as pre-built binaries. Total disk footprint: ~35MB. Total idle RAM impact: negligible (these are invoked per-command, not persistent daemons).

---

## Alias management that survives ADHD

The alias maintenance problem has an elegant two-part solution: **modular files for organization** and **zsh-you-should-use for rediscovery**.

Split aliases into category files under `~/.config/zsh/aliases/`:

```
aliases/
|-- docker.zsh      # dps, dcu, dcd, dlogs
|-- git.zsh         # gs, gco, gp, gl
|-- navigation.zsh  # ..., mkcd, tmp
|-- pi.zsh          # temp, vcgencmd shortcuts
`-- system.zsh      # apt shortcuts, systemctl
```

Source them with a single glob in `.zshrc`: `for f in ~/.config/zsh/aliases/*.zsh; do source "$f"; done`. Each file stays small enough to scan in seconds — critical for ADHD users who need to quickly find and edit aliases without getting lost in a 200-line monolith.

**The rediscovery problem** (forgetting your own aliases exist) is solved by three complementary tools. First, `zsh-you-should-use` passively reminds you whenever you type a command that has an alias. Second, a simple `halp` function pipes all aliases through fzf for fuzzy searching: `alias halp='alias | fzf'`. Third, `zsh-abbr` provides fish-style abbreviations that expand inline before execution — so your command history shows full commands, not cryptic alias names, making it readable on any machine.

**For syncing across a Pi fleet**, chezmoi is the strongest choice. Its templating system handles machine-to-machine differences (different aliases for Pi 5 vs Pi Zero) within a single git branch using Go templates. A single command bootstraps a new Pi: `sh -c "$(curl -fsLS get.chezmoi.io)" -- init --apply $GITHUB_USERNAME`. The static ARM binary (~12.5MB) works on both 32-bit and 64-bit Pi. For those who find chezmoi's template syntax too complex, GNU Stow (`apt install stow`) + a git repo is the zero-overhead alternative — it just creates symlinks and requires no learning beyond that concept.

---

## MOTD that orients you across a Pi fleet

When you SSH into the fifth Pi of the day, the MOTD needs to answer one question instantly: **where am I and what's happening?** The best approach combines a fetch tool with a dynamic MOTD script placed in `/etc/update-motd.d/`.

**Fastfetch is the neofetch replacement** — written in C, it's up to 10x faster than neofetch (which was archived in April 2024). It shows hostname, OS, kernel, IP address, memory, CPU temperature, and disk usage in milliseconds. Install via GitHub `.deb` release for Raspberry Pi OS (the PPA `ppa:zhangsongcui3371/fastfetch` exists but is less reliable on RPi OS — GitHub releases are preferred). For the Light tier, **pfetch-rs** (Rust rewrite of pfetch) is 10x faster still, shows only essential info, and has ARM binaries.

The hardware-adaptive MOTD script pattern:

```bash
#!/bin/bash
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")

# Color-code hostname by device role (set per machine)
HOSTNAME_COLOR="\033[1;36m"  # cyan default; override per Pi
printf "${HOSTNAME_COLOR}%s\033[0m | %s\n" "$(hostname)" "$PI_MODEL"

if [ "$RAM_MB" -ge 4000 ]; then
    fastfetch -s OS:Kernel:Uptime:Memory:Disk:LocalIP:CPU:CPUUsage:GPU
elif [ "$RAM_MB" -ge 1000 ]; then
    fastfetch -s Title:OS:Uptime:Memory:LocalIP
else
    PF_INFO="ascii title os host kernel uptime memory" pfetch 2>/dev/null || \
    printf "RAM: %sMB | Up: %s | IP: %s\n" "$RAM_MB" "$(uptime -p)" \
           "$(hostname -I | awk '{print $1}')"
fi
```

Add personality with `fortune | cowsay` (Light tier: skip cowsay, just fortune), `figlet $(hostname)` for large text hostnames, or a rotating ASCII art raspberry. The ar51an/raspberrypi-motd GitHub repo provides a battle-tested three-script setup with systemd timer for update counts.

**Color-coding by role** is the highest-impact orientation trick: production Pis display red hostnames, dev Pis green, monitoring blue. This single visual cue prevents the catastrophic "wrong Pi" mistake that ADHD users are especially vulnerable to.

---

## Bootstrap script architecture

The script uses a layered detection system: first determine if you're on a Pi, then identify the model, RAM tier, OS, and architecture. These values drive every subsequent installation decision.

### Hardware detection (the reliable way)

```bash
detect_hardware() {
    # Model detection -- /proc/device-tree/model is authoritative
    # WARNING: /proc/cpuinfo "Hardware" field shows "BCM2835" for ALL Pi models
    PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Not a Pi")

    # SoC detection for tier assignment
    local compat=$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null)
    case "$compat" in
        *bcm2712*) PI_SOC="bcm2712" ;;  # Pi 5
        *bcm2711*) PI_SOC="bcm2711" ;;  # Pi 4
        *bcm2837*) PI_SOC="bcm2837" ;;  # Pi 3 / Zero 2W
        *bcm2836*) PI_SOC="bcm2836" ;;  # Pi 2
        *bcm2835*) PI_SOC="bcm2835" ;;  # Pi 1 / Zero (original)
        *)         PI_SOC="unknown"  ;;
    esac

    # RAM tier -- drives tool selection
    RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
    if [ "$RAM_MB" -ge 4000 ]; then TIER="full"
    elif [ "$RAM_MB" -ge 1000 ]; then TIER="standard"
    else TIER="light"; fi

    # Architecture -- CRITICAL: use dpkg, not uname
    # Pi can run 64-bit kernel with 32-bit userland
    ARCH=$(dpkg --print-architecture 2>/dev/null || echo "unknown")
    # ARCH will be "arm64" or "armhf"

    # OS detection
    . /etc/os-release 2>/dev/null
    DISTRO="${ID:-unknown}"           # raspbian, debian, ubuntu
    DISTRO_VERSION="${VERSION_ID:-0}" # 12, 24.04
    CODENAME="${VERSION_CODENAME:-unknown}" # bookworm, noble
}
```

### Idempotent design patterns

Every operation must be safe to re-run. The key patterns: `mkdir -p` (won't error if exists), `ln -sfn` (forces symlink recreation), `apt-get install -y` (already idempotent), and grep-guarded file appends:

```bash
ensure_line_in_file() {
    local line="$1" file="$2"
    grep -qF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

install_if_missing() {
    local cmd="$1" install_fn="$2"
    if ! command -v "$cmd" &>/dev/null; then
        info "Installing $cmd..."
        eval "$install_fn"
    else
        success "$cmd already installed"
    fi
}
```

Wrap the entire script in a `main()` function called on the last line — this prevents partial execution if the download is interrupted during `curl | bash`.

### Security for curl | bash

The primary risk is partial execution, not the pipe mechanism itself. Mitigations: wrap in `main()`, serve over HTTPS only, pin to a specific git tag (not `main` branch), and offer a two-step alternative for verification: `curl -fsSL URL -o setup.sh && less setup.sh && bash setup.sh`.

---

## Notification tools for long-running commands

ADHD users universally report the pattern: start a long command, switch context, completely forget it exists. Three solutions at different complexity levels:

**ntfy.sh via curl** (zero overhead, works everywhere): `curl -d "Build complete on $(hostname)" ntfy.sh/your-topic`. Sends push notifications to your phone. No daemon, no installation, works on every Pi including Zero. Self-hostable on Pi 4+ if you want privacy.

**Shell integration for automatic notifications**: Add to `.zshrc` a precmd/preexec hook that measures command duration and sends a notification for anything over 30 seconds. The Python `ntfy` package (`pip install ntfy`) provides `eval "$(ntfy shell-integration)"` for automatic detection.

**undistract-me** (Ubuntu/desktop only): Pure shell script (<10KB) that sends desktop notifications when commands taking >10 seconds complete. Only useful on GUI sessions, not headless SSH — so limited applicability for headless Pi fleet.

---

## Conclusion: the stack, distilled

The entire ADHD-friendly CLI stack rests on a tier-aware foundation that respects hardware constraints without sacrificing the dopamine-friendly aesthetics that keep ADHD users engaged. The most impactful discoveries from this research aren't individual tools — they're patterns.

**The highest-ROI change is zsh-you-should-use**, which solves the alias amnesia problem that plagues every ADHD shell user. It passively teaches you your own shortcuts instead of requiring you to remember them. Combined with fzf (fuzzy-find literally everything) and zsh-autosuggestions (never retype from memory), these three plugins address the core working-memory deficit more effectively than any amount of terminal beautification.

**Catppuccin Mocha as a universal theme** eliminates the "which color scheme" decision permanently — its 300+ official ports mean you configure once and every tool matches. The consistency itself reduces cognitive load in a way that's easy to underestimate.

**The tier split works cleanly**: Pi Zero gets tmux + Powerlevel10k + pfetch + htop (total overhead: ~15MB RAM). Pi 5 gets Zellij + Starship + fastfetch + btop + lazygit + the full Rust CLI toolkit (total overhead: ~150MB RAM, trivial on 4GB+). The bootstrap script detects hardware and makes the right choice automatically — one less decision for the ADHD brain to make.

The most counterintuitive finding: **restraint is the killer feature**. Limiting zsh plugins to 6, aliases to categorized files of <=20 lines each, and configuration to tools with good defaults prevents the script itself from becoming the next yak-shaving project. The bootstrap should feel finished after one run — not like a permanent work-in-progress.
