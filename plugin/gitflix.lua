-- GitFlix: Neovim plugin entrypoints

vim.keymap.set("n", "<leader>gm", function()
	require("gitflix").play()
end, { desc = "GitFlix: play git history" })

vim.api.nvim_create_user_command("GitFlix", function()
	require("gitflix").play()
end, {})
