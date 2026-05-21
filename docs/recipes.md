# Recipes

This page shows practical ways to wire `editr.nvim` into an existing Neovim
setup. The goal is to keep normal mappings working locally while routing to
remote-aware tools inside sessions launched by `editr`.

For shell wrappers, ignore patterns, and editor-agnostic setup, see the core
[`editr` recipes](https://github.com/serhez/editr/blob/main/docs/recipes.md).

## Lazy.nvim Setup

```lua
{
  "serhez/editr.nvim",
  cmd = {
    "EditrInfo",
    "EditrRemoteFiles",
    "EditrRemoteGrep",
    "EditrCanola",
    "EditrOil",
    "EditrHydrate",
  },
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
  },
}
```

`editr.nvim` is inactive unless Neovim was launched by `editr`.

## One Mapping For Files

Route your normal file picker mapping through `editr` first. Outside an `editr`
session, the fallback runs as usual.

```lua
local router = require("editr.router")

vim.keymap.set("n", "<leader>f", router.map({
  router.editr("files"),
}, function()
  require("snacks").picker.files()
end), { desc = "Find files" })
```

Inside an `editr` session this runs the remote-aware Snacks file picker over
SSH and opens the selected file from the local mirror.

## One Mapping For Grep

```lua
local router = require("editr.router")

vim.keymap.set("n", "<leader>s", router.map({
  router.editr("grep"),
}, function()
  require("snacks").picker.grep()
end), { desc = "Search text" })
```

The remote picker prefers `rg`, then `git grep`, then `find + grep` on the SSH
host. Results are mapped back into the local mirror when opened.

## One Mapping For Explorer

Use canola remotely and your normal explorer locally:

```lua
local router = require("editr.router")

vim.keymap.set("n", "<leader>e", router.map({
  router.editr("explorer"),
}, function()
  require("oil").open()
end), { desc = "Explorer" })
```

If you prefer oil for the remote explorer too, use `router.editr("oil")`
instead of `router.editr("explorer")`.

## Route canola Selection Back To The Mirror

When browsing remote directories with canola, route file selection through
`editr`. Synced files open from the local mirror; ignored remote-only files go
through the hydration policy.

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

This avoids mixing normal editing buffers with `canola-ssh://` file buffers
when a mirror path is available.

## Compose With Other Contexts

If you already route mappings for other special contexts, add `editr` as one
handler in the list:

```lua
local router = require("editr.router")

vim.keymap.set("n", "<leader>s", router.map({
  function()
    local ok, project = pcall(require, "my_project_picker")
    return ok and project.is_active() and project.grep() ~= false
  end,
  router.editr("grep"),
}, function()
  require("snacks").picker.grep()
end), { desc = "Search text" })
```

Handlers should return `true` when they handled the mapping and `false` or
`nil` when the next handler should be tried.

## Hydration Defaults

For large ignored paths, a conservative setup is:

```lua
require("editr").setup({
  remote_open_policy = "auto_under_limit",
  max_auto_hydrate_size = "25 MB",
  hydration_mode = "live",
  flush_on_write = true,
})
```

With this policy, small remote-only files hydrate automatically, while large or
unknown-size files prompt before downloading. Live hydration sessions are
stopped on buffer close and on `VimLeavePre`; `editr watch` handles hard-crash
cleanup from outside Neovim.

## Debugging

Use these checks when a mapping does not route the way you expect:

```vim
:EditrInfo
:EditrRemoteFiles
:EditrRemoteGrep
```

From a shell:

```sh
editr list
ssh host 'pwd; command -v rg; command -v git'
```
