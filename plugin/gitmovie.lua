-- GitMovie: Neovim plugin entrypoints
-- Unified command: :GitMovie [subcommand] [args...]
vim.api.nvim_create_user_command('GitMovie', function(opts)
  local args = opts and opts.args or ""
  local parts = {}
  for w in string.gmatch(args, "%S+") do table.insert(parts, w) end
  local sub = parts[1]
  local arg1 = parts[2]

  if not sub or sub == "" then
    -- open viewer in non-playing mode for current repo
    require('gitmovie').open_view(arg1)
    return
  end

  if sub == "start" or sub == "play" then
    require('gitmovie').start(arg1)
  elseif sub == "stop" then
    require('gitmovie').stop()
  elseif sub == "setrepo" or sub == "set_repo" or sub == "set-repo" then
    require('gitmovie').set_repo(arg1)
  elseif sub == "speed" or sub == "set_speed" or sub == "speed-ms" then
    local n = tonumber(arg1)
    require('gitmovie').set_speed(n or 100)
  elseif sub == "open" or sub == "open_view" or sub == "openview" then
    require('gitmovie').open_view(arg1)
  elseif sub == "help" or sub == "h" then
    require('gitmovie').show_help()
  else
    vim.notify("GitMovie: unknown command. Use :GitMovie for help.")
    require('gitmovie').show_help()
  end
end, {nargs='?'})
