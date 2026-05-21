# editr.nvim

[![CI](https://github.com/serhez/editr.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/serhez/editr.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Neovim integration for [`editr`](https://github.com/serhez/editr).

`editr.nvim` is inactive during normal local editing. When Neovim is launched
by `editr`, it reads `EDITR_CONTEXT` and teaches Neovim integrations how to
work with the remote project and the local mirror at the same time.

Install the core CLI from [`serhez/editr`](https://github.com/serhez/editr);
this plugin only provides the optional Neovim-side integrations.

## What It Adds

- Snacks file and grep pickers for the remote project.
- canola/oil explorer entry points for lazy remote browsing.
- Selection routing from canola back into the local mirror.
- Hydration for ignored remote-only files.
- Router helpers for existing keymaps.

The goal is that your normal mappings keep working. In an `editr` session they
route to remote-aware tools; outside an `editr` session they fall back to your
normal local tools.

## Requirements

- [`editr`](https://github.com/serhez/editr) on `$PATH`
- Neovim with `vim.system`
- Optional: [`snacks.nvim`](https://github.com/folke/snacks.nvim)
- Optional: `canola.nvim` or `oil.nvim`

## Installation

Lazy.nvim example:

```lua
{
  "serhez/editr.nvim",
  opts = {
    editr_bin = "editr",
    integrations = {
      snacks = true,
      canola = true,
      oil = true,
    },
    remote_open_policy = "auto_under_limit",
    max_auto_hydrate_size = "25 MB",
    hydration_mode = "live",
    flush_on_write = true,
    ssh_args = {},
  },
}
```

Then launch Neovim through `editr`:

```sh
editr host:/absolute/remote/project
```

The plugin does nothing when `EDITR_CONTEXT` is absent.

See [Recipes](docs/recipes.md) for complete mapping, picker, canola/oil, and
hydration examples.

## Commands

- `:EditrInfo` shows the active context.
- `:EditrRemoteFiles` opens the Snacks remote file picker.
- `:EditrRemoteGrep` opens the Snacks remote grep picker.
- `:EditrCanola` opens the remote root with canola.
- `:EditrOil` opens the remote root with oil.
- `:EditrHydrate [remote-path]` hydrates a remote file into the mirror.

## Existing Keymaps

Use `editr.router` to keep one mapping for local and remote work.

Files:

```lua
local router = require("editr.router")

vim.keymap.set("n", "<leader>f", router.map({
  router.editr("files"),
}, function()
  require("snacks").picker.files()
end), { desc = "Find files" })
```

Grep:

```lua
local router = require("editr.router")

vim.keymap.set("n", "<leader>s", router.map({
  router.editr("grep"),
}, function()
  require("snacks").picker.grep()
end), { desc = "Search text" })
```

Explorer:

```lua
local router = require("editr.router")

vim.keymap.set("n", "<leader>e", router.map({
  router.editr("explorer"),
}, function()
  require("oil").open()
end), { desc = "Explorer" })
```

`router.editr("explorer")` opens canola. If you prefer oil for the remote
explorer, use `router.editr("oil")`.

`router.first()` and `router.map()` accept handlers that return `true` when
they handled the mapping. This makes it easy to combine `editr` with your own
context-aware integrations:

```lua
vim.keymap.set("n", "<leader>s", router.map({
  function()
    local ok, overleaf = pcall(require, "overleaf")
    return ok and overleaf.is_overleaf_context(0) and overleaf.search() ~= false
  end,
  router.editr("grep"),
}, function()
  require("snacks").picker.grep()
end))
```

For simple fallback handlers, `router.module("module", "method")` builds the
handler for you.

## canola Selection

When browsing with canola, route file selection through `editr` so synced files
open from the local mirror and ignored files go through the hydration policy:

```lua
["<CR>"] = {
  desc = "Select",
  callback = function()
    if not require("editr").canola_select({ close = true }) then
      require("canola").select({ close = true })
    end
  end,
}
```

The plugin maps remote paths back to the local mirror when possible. It also
handles remote roots where the logical SSH path resolves to a different
physical path, for example when `/home/user/project` is a symlink.

## Hydration Policy

Hydration means syncing one remote file into the local mirror. This is useful
for files under ignored paths, such as logs or generated artifacts.

Policies:

- `auto_under_limit`: open local files directly; hydrate remote-only files under
  `max_auto_hydrate_size`; prompt for larger or unknown-size files.
- `hydrate`: hydrate selected remote-only files.
- `remote`: open remote buffers without hydrating.
- `prompt`: always ask.

Live hydration creates a per-file Mutagen session. `editr.nvim` stops that
session on buffer close and on `VimLeavePre`. Hard crashes are handled by
`editr watch`.

## How the Pickers Work

The Snacks pickers run search commands over SSH against the remote root and map
results back into the local mirror:

- File picker prefers `git ls-files`, then `fd`/`fdfind`, then `rg --files`,
  then `find`.
- Grep picker prefers `rg`, then `git grep`, then `find + grep`.

Selecting a result opens the local mirror path when it exists. If the selected
file is remote-only, the hydration policy decides what happens next.

## Troubleshooting

- `:EditrInfo` should show the active context. If it does not, Neovim was not
  launched by `editr`.
- If remote pickers fail, first check that plain SSH commands work:
  `ssh host 'pwd; command -v rg; command -v git'`.
- If a hydrated file keeps syncing after Neovim exits, run `editr list` and
  `editr stop <session>`.
- If local Git looks wrong, check whether a tracked path is ignored by Mutagen.

More recovery guidance lives in the core `editr` troubleshooting docs.
