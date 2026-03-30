# nvim-fundo

The goal of nvim-fundo is to make Neovim's undo file become stable and useful.

<https://user-images.githubusercontent.com/17562139/202656014-85bc84ca-30b1-4093-9546-a06f17effc73.mp4>

> WIP. If you like this plugin, star it to let me speed up to end WIP state.

## Features

- Restore undo history even if the file's content has been changed outside Neovim
- Limit size for archives

### TODO Features

- Restore undo history even if the file has been moved
- Support useful use cases for undo file

## Quickstart

### Requirements

- [Neovim](https://github.com/neovim/neovim) 0.7.2 or later

### Installation

Install with [Packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
    'ofseed/nvim-fundo', branch = 'nvim-plugin', requires = 'lewis6991/async.nvim'
}
```

### Minimal configuration

```lua
use {
    'ofseed/nvim-fundo', branch = 'nvim-plugin', requires = 'lewis6991/async.nvim'
}

vim.o.undofile = true
require('fundo').setup()
```

### Usage

Use undo file as usual.

## Documentation

### How does nvim-undo keep the undo history?

Fundo will keep the latest files as archives, in other words, it takes additional space in your
disk. If the `BufReadPost` event is fired, it will validate the undo file and restore it if
necessary.

### Setup and description

```lua
{
    archives_dir = {
        description = [[The directory to store the archives]],
        default = vim.fs.joinpath(vim.fn.stdpath('cache'), 'fundo')
    },
    limit_archives_size = {
        description = [[Limit the archives directory size, unit is MB(megabyte), elder files will be
        removed based on their modified time]],
        default = 512
    }
}
```

### API

[fundo.lua](./lua/fundo.lua)

## Refactor Summary

The original plugin grew a number of internal helper layers over time: async wrappers, fs wrappers,
event/disposable helpers, path helpers, synchronization helpers, and several small internal
modules.

This codebase has since been heavily simplified with the goal of keeping the runtime behavior the
same while removing internal indirection:

- Async support now depends directly on `async.nvim`
- Command registration and default startup now live in `plugin/fundo.lua`
- The remaining runtime implementation has been flattened into [`lua/fundo.lua`](./lua/fundo.lua)
- Internal wrapper layers such as custom fs/path/event/disposable/semaphore abstractions were removed

Compared with the pre-refactor baseline, the Lua runtime code was reduced from:

- 15 Lua files under `lua/` to 1
- 12 documented internal classes to 3 (`FundoConfig`, `FundoUndo`, and `FundoManager`)
- 1562 lines of Lua code under `lua/` to 451

In short, `nvim-fundo` is now implemented as a much flatter plugin with fewer moving parts and
less internal abstraction.

## Feedback

- If you get an issue or come up with an awesome idea, don't hesitate to open an issue in github.
- If you think this plugin is useful or cool, consider rewarding it a star.

## License

The project is licensed under a BSD-3-clause license. See [LICENSE](./LICENSE) file for details.
