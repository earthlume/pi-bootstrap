# pi-bootstrap

ADHD-friendly shell setup for Raspberry Pi. One command, zero decisions.

Auto-detects your hardware, picks the right tier, and installs a modern
zsh environment with Catppuccin Mocha theming, sensible defaults, and
dopamine-friendly feedback -- so you can skip the yak-shaving and get
to the fun part.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/earthlume/pi-bootstrap/main/pi-bootstrap.sh | bash
```

**On slow WiFi or flaky SSH?** Download first, then run:

```bash
curl -fsSL -o /tmp/pi-bootstrap.sh https://raw.githubusercontent.com/earthlume/pi-bootstrap/main/pi-bootstrap.sh
bash /tmp/pi-bootstrap.sh
```

Or clone and run locally:

```bash
git clone https://github.com/earthlume/pi-bootstrap.git
bash pi-bootstrap/pi-bootstrap.sh
```

After it finishes, log out and back in (or run `exec zsh`).

## What It Installs

### Shell Stack

| Component | Full | Standard | Light |
|-----------|------|----------|-------|
| **zsh** | Y | Y | Y |
| **Antidote** (plugin manager) | Y | Y | Y |
| **Starship** (prompt) | Y | - | - |
| **Powerlevel10k** (prompt) | - | Y | Y |
| **MesloLGS NF** (Nerd Font) | - | Y | Y |
| **tmux** + Catppuccin | Y | Y | Y |
| **Zellij** (arm64 only) | Y | - | - |

### ZSH Plugins (via Antidote)

| Plugin | What it does |
|--------|-------------|
| **zsh-autosuggestions** | Fish-like history suggestions (gray inline text) |
| **zsh-syntax-highlighting** | Live command coloring (green=valid, red=error) |
| **zsh-completions** | Extra completion definitions |
| **zsh-you-should-use** | Reminds you of your own aliases |
| **zsh-abbr** | Fish-style abbreviations that expand inline |

### CLI Tools

| Tool | Replaces | Full | Standard | Light |
|------|----------|------|----------|-------|
| **fzf** | history search | Y | Y | Y |
| **zoxide** | cd/z | Y | Y | Y |
| **ripgrep** | grep | Y | Y | Y |
| **bat** | cat | Y | Y | Y |
| **fd** | find | Y | Y | Y |
| **tealdeer** | man/tldr | Y | Y | Y |
| **duf** | df | Y | Y | Y |
| **ncdu** | du | Y | Y | Y |
| **htop** | top | Y | Y | Y |
| **btop** | htop | Y | Y | - |
| **eza** | ls | Y | - | - |
| **delta** | diff | Y | - | - |
| **dust** | du | Y | - | - |
| **glow** | less (md) | Y | - | - |
| **lazygit** | git CLI | Y | - | - |
| **lazydocker** | docker CLI | Y | - | - |
| **fastfetch** | neofetch | Y | - | - |
| **neovim** | vim | Y | Y | Y |

### Theme

**Catppuccin Mocha** applied to: fzf, bat, btop, delta/git, tmux, Zellij, Starship.
Consistent pastel palette across every tool -- one fewer decision to make.

## Flags

```
bash pi-bootstrap.sh [OPTIONS]
```

| Flag | Description |
|------|-------------|
| `--optimize` | Apply safe system tweaks (swappiness, journald limits, PCIe Gen 3, fan curve) |
| `--update-os` | Run `apt upgrade` before installing (kernel/firmware held) |
| `--no-chsh` | Don't change default shell to zsh |
| `--no-motd` | Skip custom MOTD installation |
| `--info-only` | Print system diagnostics and exit |
| `--dry-run` | Show what would be installed without doing it |
| `--tier-override=TIER` | Force a specific tier: `light`, `standard`, or `full` |
| `--uninstall` | Remove pi-bootstrap configs (restores backups, keeps apt packages) |

## Tiers

The script auto-selects a tier based on your Pi's hardware:

| | Full | Standard | Light |
|---|------|----------|-------|
| **When** | 4GB+ RAM, 64-bit | 1-4GB RAM | <1GB RAM |
| **Prompt** | Starship | Powerlevel10k | Powerlevel10k (minimal) |
| **Multiplexer** | tmux + Zellij | tmux | tmux |
| **Git status** | Fast (Starship async) | gitstatus (async) | Fallback (lighter) |
| **System monitor** | btop + fastfetch | btop | htop |
| **Extra tools** | eza, delta, dust, glow, lazygit, lazydocker | btop | - |

## Files Created

| File | What |
|------|------|
| `~/.zshrc` | Shell config with ADHD-friendly defaults |
| `~/.zsh_plugins.txt` | Antidote plugin list |
| `~/.p10k.zsh` | Powerlevel10k config (standard/light tiers) |
| `~/.config/starship.toml` | Starship config with Catppuccin (full tier) |
| `~/.config/zsh/aliases/*.zsh` | Modular alias files |
| `~/.tmux.conf` | tmux config with Catppuccin |
| `~/.config/zellij/` | Zellij config (full tier) |
| `~/.config/bat/themes/` | Catppuccin bat theme |
| `~/.config/btop/themes/` | Catppuccin btop theme |
| `/etc/profile.d/99-earthlume-motd.sh` | Dynamic login banner |
| `/etc/pi-info` | Network info (MAC + IP for static leases) |
| `~/.pi-bootstrap-backups/<timestamp>/` | Backup of any overwritten configs |
| `~/.adhd-bootstrap.log` | Install log |

## .zshrc Highlights

- **History**: 50k entries, deduplicated, shared across terminals, written immediately
- **Auto-correction**: Suggests fixes for typos
- **Auto-cd**: Type a directory name to `cd` into it
- **Auto-ls**: Automatically lists directory contents after every `cd`
- **Arrow key history search**: Type `git` then press Up to find previous git commands
- **Colored man pages**: Cyan headings, green flags, yellow search hits
- **Terminal title**: Shows `user@host: ~/dir` so you can identify tabs at a glance
- **Long command bell**: Rings after commands that take >30s
- **ntfy.sh notifications**: Push notification to your phone for commands >60s (configure topic)
- **Command not found**: Suggests which package to install
- **Safety aliases**: `rm`, `cp`, `mv` prompt before overwriting

## ADHD Tools

| Command | What it does |
|---------|-------------|
| `halp` | Fuzzy-search all aliases with fzf |
| `whereami` | Context recovery -- shows dir, user, git status, recent commands |
| `today` | Daily journal -- recent commands, modified files, git activity |
| `notify-done` | Send push notification via ntfy.sh |
| `aliases search <keyword>` | Filter alias list by keyword |

## Alias Quick Reference

| Alias | Command |
|-------|---------|
| `ll` | `ls -lah` (or `eza -la --icons` on full tier) |
| `..` / `...` | Navigate up directories |
| `update` | `sudo apt update && sudo apt upgrade -y` |
| `temp` | Show CPU temperature |
| `ports` | Show listening ports |
| `myip` | Show public IP |
| `gs` / `gd` / `gl` | git status / diff / log |
| `dps` / `dcu` / `dcd` | docker ps / compose up / compose down |
| `mkcd <dir>` | Create directory and cd into it |

## ntfy.sh Integration

Get push notifications when long commands finish:

```bash
# Set your ntfy.sh topic (one-time setup)
mkdir -p ~/.config/adhd-kit
echo "your-topic-name" > ~/.config/adhd-kit/ntfy-topic

# Commands taking >60 seconds auto-notify
# Or manually send a notification:
notify-done "Build finished on $(hostname)"
```

Subscribe to your topic at [ntfy.sh](https://ntfy.sh) or the ntfy mobile app.

## Tested On

- Raspberry Pi 5 (8GB) -- Raspberry Pi OS Bookworm 64-bit
- Raspberry Pi 5 (8GB) -- Raspberry Pi OS Trixie 64-bit Lite

Should work on any Pi model with Bookworm or newer. Debian/Ubuntu desktops likely work too.

## Requirements

- Raspberry Pi (any model) or Debian-based Linux
- `sudo` access
- Internet connection

## Troubleshooting

**Font icons look broken?**
Configure your terminal emulator to use `MesloLGS NF` as the font.
(Only needed for standard/light tiers using Powerlevel10k.)

**Shell didn't change?**
Run manually: `chsh -s $(command -v zsh)` then log out/in.

**Want full hardware diagnostics?**
```bash
bash pi-bootstrap.sh --info-only
```

**Want to preview without installing?**
```bash
bash pi-bootstrap.sh --dry-run
```

**Want to undo everything?**
```bash
bash pi-bootstrap.sh --uninstall
```

## License

MIT
