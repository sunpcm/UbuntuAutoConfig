#!/usr/bin/env bash
# WSL Dev Environment Uninstall Script

set -e

echo "🗑️  WSL Dev Environment Uninstaller"
echo "====================================="
echo
echo "⚠️  WARNING: This will remove:"
echo "  - Homebrew and all installed packages"
echo "  - Oh My Zsh and plugins"
echo "  - nvm and Node.js"
echo "  - goenv and Go"
echo "  - uv Python tool"
echo "  - Modified configuration files (.zshrc, etc.)"
echo
read -p "Are you sure you want to continue? (yes/no): " -r
echo

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
  echo "❌ Uninstall cancelled."
  exit 0
fi

echo "🔄 Starting uninstall process..."
echo

# Backup current configs
echo "💾 Creating final backup..."
mkdir -p "$HOME/.wsl-dev-backup/uninstall-$(date +%Y%m%d_%H%M%S)"
for file in .zshrc .bashrc .gitconfig .profile .zprofile; do
  if [ -f "$HOME/$file" ]; then
    cp "$HOME/$file" "$HOME/.wsl-dev-backup/uninstall-$(date +%Y%m%d_%H%M%S)/"
  fi
done

# Remove Homebrew
if command -v brew >/dev/null 2>&1; then
  echo "🍺 Uninstalling Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" || true
else
  echo "⚠️  Homebrew not found"
fi

# Remove Oh My Zsh
if [ -d "$HOME/.oh-my-zsh" ]; then
  echo "💤 Removing Oh My Zsh..."
  rm -rf "$HOME/.oh-my-zsh"
else
  echo "⚠️  Oh My Zsh not found"
fi

# Remove nvm
if [ -d "$HOME/.nvm" ]; then
  echo "📦 Removing nvm..."
  rm -rf "$HOME/.nvm"
else
  echo "⚠️  nvm not found"
fi

# Remove goenv
if [ -d "$HOME/.goenv" ]; then
  echo "📦 Removing goenv..."
  rm -rf "$HOME/.goenv"
else
  echo "⚠️  goenv not found"
fi

# Remove uv
if [ -f "$HOME/.cargo/bin/uv" ]; then
  echo "🐍 Removing uv..."
  rm -f "$HOME/.cargo/bin/uv"
  rm -f "$HOME/.cargo/bin/uvx"
else
  echo "⚠️  uv not found"
fi

# Remove passwordless sudo
if [ -f "/etc/sudoers.d/99-wsl-dev" ]; then
  echo "🔐 Removing passwordless sudo..."
  sudo rm -f /etc/sudoers.d/99-wsl-dev
else
  echo "⚠️  Passwordless sudo config not found"
fi

# Remove Windows integration script
if [ -f "$HOME/.wsl-windows-integration.sh" ]; then
  echo "🪟 Removing Windows integration..."
  rm -f "$HOME/.wsl-windows-integration.sh"
fi

# Remove symlinks
echo "🔗 Removing symlinks..."
for link in downloads desktop documents; do
  if [ -L "$HOME/$link" ]; then
    rm "$HOME/$link"
  fi
done

# Restore default shell configs
echo "📝 Restoring default configurations..."

# Create minimal .zshrc
cat > "$HOME/.zshrc" << 'EOF'
# Minimal .zshrc configuration
# Restored after WSL Dev Environment uninstall

# If you come from bash you might have to change your $PATH.
export PATH=$HOME/bin:$HOME/.local/bin:/usr/local/bin:$PATH

# Basic prompt
PROMPT='%n@%m:%~$ '

# Basic history configuration
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history

# Basic aliases
alias ll='ls -lh'
alias la='ls -lah'
alias grep='grep --color=auto'
EOF

# Create minimal .bashrc if it doesn't exist
if [ ! -f "$HOME/.bashrc" ]; then
  cp /etc/skel/.bashrc "$HOME/.bashrc" || true
fi

echo
echo "✅ Uninstall complete!"
echo
echo "📦 Backups are saved in: ~/.wsl-dev-backup/"
echo "💡 You may want to:"
echo "   - Restart your terminal"
echo "   - Run 'source ~/.zshrc' or 'source ~/.bashrc'"
echo "   - Remove any remaining configuration manually"
echo
