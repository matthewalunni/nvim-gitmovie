local M = {}

function M.play()
	local git = require("gitmovie.git")
	local animator = require("gitmovie.animator")

	local repo = vim.fn.getcwd()
	local commits = git.get_commits(repo)

	if #commits == 0 then
		vim.notify("GitMovie: no commits found", vim.log.levels.ERROR)
		return
	end

	local items = {}
	for i = 1, #commits do
		local c = commits[#commits - i + 1]
		items[i] = string.format("[%d/%d] %s  %s  (%s)", #commits - i + 1, #commits, c.hash:sub(1, 8), c.subject, c.date)
	end

	vim.ui.select(items, { prompt = "GitMovie: select starting commit" }, function(_, idx)
		if not idx then return end
		animator.play_from(repo, commits, #commits - idx + 1)
	end)
end

function M.stop()
	require("gitmovie.animator").stop()
end

function M.pause()
	require("gitmovie.animator").pause()
end

function M.resume()
	require("gitmovie.animator").resume()
end

return M
