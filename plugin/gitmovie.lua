-- GitMovie: Neovim plugin entrypoints
vim.api.nvim_create_user_command('GitMovieStart', function(opts)
  require('gitmovie').start(opts and opts.args or nil)
end, {nargs='?'})

vim.api.nvim_create_user_command('GitMovieStop', function()
  require('gitmovie').stop()
end, {})

vim.api.nvim_create_user_command('GitMovieSetRepo', function(opts)
  require('gitmovie').set_repo(opts.args)
end, {nargs=1})

vim.api.nvim_create_user_command('GitMovieSpeed', function(opts)
  local n = tonumber(opts.args)
  require('gitmovie').set_speed(n or 100)
end, {nargs='?'})
