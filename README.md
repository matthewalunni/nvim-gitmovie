# GitFlix

A Neovim plugin that replays git commits as animated diffs, allowing you to visualize the evolution of a codebase over time.

## Overview

GitFlix creates an animated visualization of your git history, showing each commit's diff in sequence. It displays the changes in a floating window with syntax highlighting:

- **Green** for added lines (typed out with a typewriter effect)
- **Red** for deleted lines (highlighted then removed)
- **Gray** for context lines

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'matthewalunni/gitflix.nvim',
  keys = {
    { '<leader>gm', '<cmd>GitFlix<cr>', desc = 'GitFlix: play git history' },
  }
}
```

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use { 'matthewalunni/gitflix.nvim' }
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'matthewalunni/gitflix.nvim'
```

## Usage

1. Run `:GitFlix` (or press `<leader>gm`) from within a git repository.
2. A picker appears listing all commits — select the commit you want to start from.
3. The animation begins, replaying each commit's diff from that point forward.

### Controls

| Key     | Action         |
| ------- | -------------- |
| `<Space>` | Pause / resume |
| `q`     | Quit           |

## Commands

| Command     | Description                                         |
| ----------- | --------------------------------------------------- |
| `:GitFlix` | Open commit picker and start animated diff playback |

## Features

- **Commit picker**: Choose any starting commit via an interactive selector
- **Animated diff visualization**: Watch your codebase evolve commit by commit
- **Typewriter effect**: Addition lines are typed out one at a time
- **Floating window display**: Clean, focused presentation in a centered floating window
- **Syntax highlighting**: Color-coded additions, deletions, and context with filetype-aware highlighting
- **Status bar**: Live display of current commit, file, and playback controls
- **Pause / resume**: Step through the animation at your own pace
- **Multi-file commits**: Handles commits that touch multiple files sequentially

## Requirements

- Neovim 0.5.0 or higher
- Git installed and available in your PATH
- A git repository to visualize

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Inspiration

GitFlix was inspired by the desire to better understand code evolution and visualize the development process in an intuitive, animated format.
