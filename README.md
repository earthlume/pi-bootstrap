# pi-bootstrap

ADHD-friendly shell setup for Raspberry Pi. One command, zero decisions.

Auto-detects your hardware, picks the right config, and installs a modern
zsh environment with sensible defaults — so you can skip the yak-shaving
and get to the fun part.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/Eecholume/pi-bootstrap/main/pi-bootstrap.sh | bash
```

**On slow WiFi or flaky SSH?** Download first, then run:

```bash
curl -fsSL -o /tmp/pi-bootstrap.sh https://raw.githubusercontent.com/Eecholume/pi-bootstrap/main/pi-bootstrap.sh
bash /tmp/pi-bootstrap.sh
```

Or clone and run locally:

```bash
git clone https://github.com/Eecholume/pi-bootstrap.git
bash pi-bootstrap/pi-bootstrap.sh
```

After it finishes, log out and back in (or run `exec zsh`).

## What It Installs

| Component | Purpose |
|-----------|---------|
| **zsh** | Modern shell (replaces bash as default) |
| **oh-my-zsh** | Plugin/theme framework |
| **powerlevel10k** | Fast, informative prompt theme |
| **MesloLGS NF** | Nerd Font for icons in prompt |
| **zsh-autosuggestions** | Fish-like history suggestions |
| **zsh-syntax-highlighting** | Live command coloring (FULL tier) |
| **btop** | Pretty system monitor |
| **ncdu** | Interactive disk usage viewer |
| **tree, jq** | Handy CLI utilities |
| **Custom MOTD** | Dynamic login banner with system stats |

## Flags

```
bash pi-bootstrap.sh [OPTIONS]
```

| Flag | Description |
|------|-------------|
| `--optimize` | Apply safe system tweaks (swappiness, journald limits) to extend SD card life |
| `--update-os` | Run `apt upgrade` before installing (may include kernel/firmware) |
| `--no-chsh` | Don't change default shell to zsh |
| `--no-motd` | Skip custom MOTD installation |
| `--info-only` | Print system diagnostics and exit (useful for pasting to support) |

## Tiers

The script auto-selects a tier based on your Pi's hardware:

| | FULL | LITE |
|---|------|------|
| **When** | 2GB+ RAM, 64-bit | Pi Zero, <2GB, 32-bit |
| **Plugins** | autosuggestions + syntax-highlighting | autosuggestions only |
| **Prompt** | Nerd Font icons | ASCII-only |
| **Git status** | gitstatus (fast, async) | Fallback (lighter) |

## Files Created

| File | What |
|------|------|
| `~/.zshrc` | Shell config with ADHD-friendly defaults |
| `~/.p10k.zsh` | Pre-configured prompt (no wizard needed) |
| `/etc/profile.d/99-echolume-motd.sh` | Dynamic login banner |
| `~/.pi-bootstrap-backups/<timestamp>/` | Backup of any overwritten configs |
| `~/pi-bootstrap.log` | Install log |

## .zshrc Highlights

- **History**: 50k entries, deduplicated, shared across terminals, written immediately
- **Auto-correction**: Suggests fixes for typos
- **Auto-cd**: Type a directory name to `cd` into it
- **Auto-ls**: Automatically lists directory contents after every `cd`
- **Arrow key history search**: Type `git` then press Up to find previous git commands
- **Colored man pages**: Cyan headings, green flags, yellow search hits
- **Terminal title**: Shows `user@host: ~/dir` so you can identify tabs at a glance
- **Long command bell**: Rings after commands that take >30s (helps with task-switching)
- **Command not found**: Suggests which package to install when a command is missing
- **Safety aliases**: `rm`, `cp`, `mv` prompt before overwriting
- **Useful aliases**: `ll`, `..`, `update`, `temp`, `ports`, `myip`, `gs`/`gd`/`gl` for git
- **Prompt customization**: Run `p10k configure` anytime to design a unique style per machine

## Tested On

- Raspberry Pi 5 (8GB) — Raspberry Pi OS Bookworm 64-bit
- Raspberry Pi 5 (8GB) — Raspberry Pi OS Trixie 64-bit Lite

Should work on any Pi model with Bookworm or newer. Debian/Ubuntu desktops likely work too.

## Requirements

- Raspberry Pi (any model) or Debian-based Linux
- `sudo` access
- Internet connection

## Troubleshooting

**Font icons look broken?**
Configure your terminal emulator to use `MesloLGS NF` as the font.

**Shell didn't change?**
Run manually: `chsh -s $(command -v zsh)` then log out/in.

**Want full hardware diagnostics?**
```bash
bash pi-bootstrap.sh --info-only
```
Paste the output to share your system profile.

## License

MIT
