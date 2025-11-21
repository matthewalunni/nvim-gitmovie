-- GitMovie: Neovim plugin entrypoints

-- Main GitMovie command
vim.api.nvim_create_user_command("GitMovie", function()
	require("gitmovie").open_movie_player()
end, {})
