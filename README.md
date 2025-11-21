# GitMovie WIP

A Neovim plugin that replays git commits as animated diffs, allowing you to visualize the evolution of a codebase over time.

## Overview

GitMovie creates an animated visualization of your git history, showing each commit's diff in sequence. It displays the changes in a floating window with syntax highlighting:

- **Green** for added lines
- **Red** for deleted lines
- **Gray** for context lines

## Installation

### Using [packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  'matthewalunni/nvim-gitmovie',
  config = function()
    -- Optional: Set up keybindings
    vim.api.nvim_set_keymap('n', '<leader>gms', ':GitMovieStart<CR>', { noremap = true, desc = "Start GitMovie" })
    vim.api.nvim_set_keymap('n', '<leader>gmt', ':GitMovieStop<CR>', { noremap = true, desc = "Stop GitMovie" })
  end
}
```

### Using [vim-plug](https://github.com/junegunn/vim-plug)

```vim
Plug 'matthewalunni/nvim-gitmovie'
```

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  'matthewalunni/nvim-gitmovie',
  config = function()
    -- Optional configuration
  end,
  keys = {
    { '<leader>gms', '<cmd>GitMovieStart<cr>', desc = 'Start GitMovie' },
    { '<leader>gmt', '<cmd>GitMovieStop<cr>', desc = 'Stop GitMovie' },
  }
}
```

## Usage

### Basic Usage

1. **Start replay in current directory:**

   ```vim
   :GitMovieStart
   ```

2. **Start replay for specific repository:**

   ```vim
   :GitMovieStart /path/to/your/repo
   ```

3. **Stop the animation:**
   ```vim
   :GitMovieStop
   ```

### Configuration

1. **Set repository path:**

   ```vim
   :GitMovieSetRepo /path/to/your/repo
   ```

2. **Adjust animation speed (milliseconds per frame):**
   ```vim
   :GitMovieSpeed 50   " Faster (50ms per frame)
   :GitMovieSpeed 200  " Slower (200ms per frame)
   ```

### Example Workflow

```vim
" Navigate to your project directory
:cd /path/to/your/project

" Start the animation with default speed (100ms per frame)
:GitMovieStart

" If you want to speed it up
:GitMovieSpeed 50

" Stop when done
:GitMovieStop
```

## Commands

| Command           | Arguments     | Description                                                   |
| ----------------- | ------------- | ------------------------------------------------------------- |
| `GitMovieStart`   | `[repo_path]` | Start replay from the given repo or current working directory |
| `GitMovieStop`    | -             | Stop the animation and close the viewer                       |
| `GitMovieSetRepo` | `<path>`      | Set the repository path for subsequent commands               |
| `GitMovieSpeed`   | `[ms]`        | Set animation speed in milliseconds per frame (default: 100)  |

## Features

- **Animated diff visualization**: Watch your codebase evolve commit by commit
- **Floating window display**: Clean, focused presentation in a centered floating window
- **Syntax highlighting**: Color-coded additions, deletions, and context
- **Speed control**: Adjust playback speed to your preference
- **Flexible repository selection**: Work with any git repository on your system
- **Automatic sizing**: Window automatically scales to 90% of screen width and 80% of height

## Requirements

- Neovim 0.5.0 or higher
- Git installed and available in your PATH
- A git repository to visualize

## Configuration Options

You can customize the default behavior by setting these values in your Neovim configuration:

```lua
-- Set default animation speed (milliseconds per frame)
vim.g.gitmovie_speed = 100

-- Set default repository path
vim.g.gitmovie_repo = "/path/to/your/default/repo"
```

## Keybinding Suggestions

Add these to your Neovim configuration for quick access:

```lua
-- Start GitMovie
vim.api.nvim_set_keymap('n', '<leader>gms', ':GitMovieStart<CR>', { noremap = true, silent = true, desc = "GitMovie Start" })

-- Stop GitMovie
vim.api.nvim_set_key_map('n', '<leader>gmt', ':GitMovieStop<CR>', { noremap = true, silent = true, desc = "GitMovie Stop" })

-- Set GitMovie speed
vim.api.nvim_set_keymap('n', '<leader>gmv', ':GitMovieSpeed ', { noremap = true, desc = "GitMovie Set Speed" })
```

## Troubleshooting

### "No commits found" error

- Ensure you're in a git repository with commit history
- Check that the repository path is correct
- Verify git is working: `git log` should show commits

### "Failed to read commits" error

- Ensure git is installed and accessible
- Check repository permissions
- Verify the repository is a valid git repository

### Performance issues

- Reduce the number of commits by using a shallow clone or specific branch
- Increase the animation speed with `:GitMovieSpeed`
- Close other resource-intensive applications

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Inspiration

GitMovie was inspired by the desire to better understand code evolution and visualize the development process in an intuitive, animated format.
