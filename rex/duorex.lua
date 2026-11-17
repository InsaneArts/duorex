-- duorex: an iPhone Duo in a Rex pane.
--
-- Copy this file to ~/.config/rex/duorex.lua and load it from init.lua:
--   require("duorex")
--   rex.bind("ctrl+p>i", "duorex")

local SHELL = "com.superlogical.terminal.shell"

rex.action{
  name = "duorex",
  title = "iPhone Duo",
  run = function(ctx)
    -- The device opens to the right of the pane you are in. Focus stays where you are typing.
    return rex.session.new_split{
      anchor_id = ctx.block_id,
      direction = "horizontal",
      side = "after",
      ratio = 0.6,
      focus = false,
      layout = rex.layout.block{ flavor = SHELL, options = { command = { "duorex" } } },
    }
  end,
}
