local M = {}
M.repo = nil
M.speed = 3000 -- ms per frame
M.timer = nil
M.left_buf = nil
M.right_buf = nil
M.left_win = nil
M.right_win = nil
M.ns = vim.api.nvim_create_namespace("gitmovie")

-- track commits and positions
M._commits = {}
M._index = 1 -- next-to-show index when playing
M._current = 0 -- last shown index
M._mapped = false

-- Create vertical split: left meta, right diff
local function ensure_split()
	if M.left_win and vim.api.nvim_win_is_valid(M.left_win)
		and M.right_win and vim.api.nvim_win_is_valid(M.right_win) then
		vim.api.nvim_set_current_win(M.right_win)
		return
	end
	local left_buf = vim.api.nvim_create_buf(false, true)
	local right_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(left_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(left_buf, "filetype", "gitmovie-left")
	vim.api.nvim_buf_set_option(left_buf, "modifiable", false)
	vim.api.nvim_buf_set_option(right_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(right_buf, "filetype", "gitmovie")
	vim.api.nvim_buf_set_option(right_buf, "modifiable", true)

	vim.cmd("vsplit")
	local left_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(left_win, left_buf)
	vim.cmd("wincmd l")
	local right_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(right_win, right_buf)

	local left_width = math.max(24, math.floor(vim.o.columns * 0.25))
	vim.api.nvim_win_set_width(left_win, left_width)
	vim.api.nvim_win_set_width(right_win, vim.o.columns - left_width)

	M.left_buf = left_buf
	M.left_win = left_win
	M.right_buf = right_buf
	M.right_win = right_win

	if not M._mapped then
		vim.api.nvim_buf_set_keymap(
			right_buf, "n", "j",
			"<cmd>lua require('gitmovie')._on_nav(vim.v.count1)<CR>",
			{ noremap = true, silent = true }
		)
		vim.api.nvim_buf_set_keymap(
			right_buf, "n", "h",
			"<cmd>lua require('gitmovie')._on_nav(-vim.v.count1)<CR>",
			{ noremap = true, silent = true }
		)
		vim.api.nvim_buf_set_keymap(
			right_buf, "n", "q",
			"<cmd>lua require('gitmovie').stop()<CR>",
			{ noremap = true, silent = true }
		)
		-- help mapping
		vim.api.nvim_buf_set_keymap(
			right_buf, "n", "g?",
			"<cmd>lua require('gitmovie').show_help()<CR>",
			{ noremap = true, silent = true }
		)

		M._mapped = true
	end
end

-- Build commits list (oldest first)
local function build_commits(repo)
	-- Use git rev-list to list commits oldest->newest
	local cmd = { "git", "-C", repo, "rev-list", "--reverse", "--all" }
	local out = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		vim.notify("GitMovie: failed to read commits", vim.log.levels.ERROR)
		return {}
	end
	local lines = {}
	for s in string.gmatch(out, "[^\n]+") do
		if s ~= "" then table.insert(lines, s) end
	end
	return lines
end

-- Get diff lines for a commit (filter headers, return relevant lines)
local function diff_lines(repo, hash)
	local cmd = { "git", "-C", repo, "show", "--unified=4", hash }
	local out = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then return {} end
	local lines = {}
	for line in string.gmatch(out, "[^\n]+") do
		if not (line:match("^diff ") or line:match("^index ") or line:match("^---") or line:match("^+++") ) then
			local l = line
			if l == "" then l = " " end
			table.insert(lines, l)
		end
	end
	return lines
end

local function render_right(lines)
	vim.api.nvim_buf_set_lines(M.right_buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(M.right_buf, M.ns, 0, -1)
	for i, l in ipairs(lines) do
		local hl
		if l:sub(1, 1) == "+" then hl = "GitMovieAdd"
		elseif l:sub(1, 1) == "-" then hl = "GitMovieDel"
		else hl = "GitMovieCtx" end
		if hl then vim.api.nvim_buf_add_highlight(M.right_buf, M.ns, hl, i - 1, 0, -1) end
	end
end

local function render_left(lines)
	if not M.left_buf or not vim.api.nvim_buf_is_valid(M.left_buf) then
		return
	end
	vim.api.nvim_buf_set_lines(M.left_buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(M.left_buf, M.ns, 0, -1)
end

local function update_left_for_commit(hash, subject, date, changes)
	local repoName = vim.fn.fnamemodify(M.repo, ":t")
	local left_lines = {
		"Repo: " .. repoName,
		"Commit: " .. hash .. " - " .. (subject or ""),
	}
	local date_str = date or ""
	if date_str ~= "" then date_str = date_str:gsub("\n", " ") end
	table.insert(left_lines, "Date: " .. date_str)
	table.insert(left_lines, "")
	table.insert(left_lines, "Changes:")
	if changes and #changes > 0 then
		for _, c in ipairs(changes) do table.insert(left_lines, "  " .. c) end
	end
	render_left(left_lines)
end

function M._show_index(idx)
	if not M._commits or #M._commits == 0 then
		return
	end
	if idx < 1 then idx = 1 end
	if idx > #M._commits then idx = #M._commits end
	local hash = M._commits[idx]
	local subject = vim.fn.system({ "git", "-C", M.repo, "log", "-1", "--pretty=format:%s", hash })
	local header = string.format("Commit: %s - %s", hash, subject:gsub("\\n", " "))
	local diff = diff_lines(M.repo, hash)
	local right_frame = {}
	table.insert(right_frame, header)
	for _, ln in ipairs(diff) do table.insert(right_frame, ln) end
	render_right(right_frame)
	M._current = idx
	M._index = math.min(#M._commits, M._current + 1)

	-- Update left meta pane
	local date = vim.fn.system({ "git", "-C", M.repo, "log", "-1", "--format=%ad", "--date=short", hash })
	local changes = {}
	local ch_out = vim.fn.system({ "git", "-C", M.repo, "diff-tree", "--no-commit-id", "--name-status", "-r", hash })
	if vim.v.shell_error == 0 and ch_out and ch_out ~= "" then
		for s in string.gmatch(ch_out, "[^\n]+") do
			if s ~= "" then table.insert(changes, s) end
		end
	end
	update_left_for_commit(hash, subject, date, changes)
end

function M.pause()
	if M.timer then
		pcall(function()
			M.timer:stop()
		end)
		M.timer = nil
	end
end

function M._on_nav(delta)
	if not M._commits or #M._commits == 0 then
		vim.notify("GitMovie: no commits to navigate", vim.log.levels.WARN)
		return
	end
	M.pause()
	local base = M._current
	if base == 0 then
		base = math.max(1, math.min(#M._commits, M._index))
	end
	local newidx = base + (delta or 1)
	if newidx < 1 then newidx = 1 end
	if newidx > #M._commits then newidx = #M._commits end
	M._show_index(newidx)
end

function M.set_repo(path)
	M.repo = path
	vim.notify("GitMovie: repo set to " .. tostring(path))
end

function M.set_speed(ms)
	M.speed = ms
	vim.notify("GitMovie: speed " .. tostring(ms) .. " ms/frame")
end

function M.stop()
	if M.timer then
		pcall(function() M.timer:stop() end)
		M.timer = nil
	end
	if M.right_win and vim.api.nvim_win_is_valid(M.right_win) then
		vim.api.nvim_win_close(M.right_win, true)
		M.right_win = nil
	end
	if M.left_win and vim.api.nvim_win_is_valid(M.left_win) then
		vim.api.nvim_win_close(M.left_win, true)
		M.left_win = nil
	end
	M._commits = {}
	M._index = 1
	M._current = 0
	M.left_buf = nil
	M.right_buf = nil
	M.left_win = nil
	M.right_win = nil
end

-- Open the viewer in a non-playing mode (no playback, navigate with h/j)
function M.open_view(repo_path)
	repo_path = repo_path or vim.fn.getcwd()
	M.repo = repo_path
	vim.notify("GitMovie: opening viewer for repo " .. tostring(repo_path))
	local commits = build_commits(M.repo)
	if vim.tbl_isempty(commits) then
		vim.notify("GitMovie: no commits found", vim.log.levels.ERROR)
		return
	end
	M._commits = commits
	M._index = 1
	M._current = 0
	-- Do not start timer/playback
	ensure_split()
	-- Render the first commit if available
	M._show_index(1)
end

function M.start(repo_path)
	repo_path = repo_path or vim.fn.getcwd()
	vim.notify("GitMovie: starting replay for repo " .. tostring(repo_path))
	if not repo_path or repo_path == "" then
		M.repo = vim.fn.getcwd()
	else
		M.repo = repo_path
	end

	local commits = build_commits(M.repo)
	if vim.tbl_isempty(commits) then
		vim.notify("GitMovie: no commits found", vim.log.levels.ERROR)
		return
	end
	M._commits = commits
	M._index = 1
	M._current = 0
	M.pause() -- ensure clean timer
	ensure_split()
	M.timer = vim.loop.new_timer()
	local function frame_step()
		if not M._commits or M._index > #M._commits then
			M.stop()
			vim.notify("GitMovie: replay finished")
			return
		end
		local idx = M._index
		local hash = M._commits[idx]
		local subject = vim.fn.system({ "git", "-C", repo_path, "log", "-1", "--pretty=format:%s", hash })
		local header = string.format("Commit: %s - %s", hash, subject:gsub("\\n", " "))
		local diff = diff_lines(repo_path, hash)
		local right_frame = {}
		table.insert(right_frame, header)
		for _, ln in ipairs(diff) do table.insert(right_frame, ln) end
		render_right(right_frame)
		M._current = idx
		M._index = M._index + 1
		-- refresh left meta for current commit
		local date = vim.fn.system({ "git", "-C", M.repo, "log", "-1", "--format=%ad", "--date=short", hash })
		local changes = {}
		local ch_out = vim.fn.system({ "git", "-C", M.repo, "diff-tree", "--no-commit-id", "--name-status", "-r", hash })
		if vim.v.shell_error == 0 and ch_out and ch_out ~= "" then
			for s in string.gmatch(ch_out, "[^\\n]+") do
				if s ~= "" then table.insert(changes, s) end
			end
		end
		update_left_for_commit(hash, subject, date, changes)
		if M._index > #M._commits then
			vim.defer_fn(function() M.stop() end, 400)
		end
	end

	M.timer:start(0, M.speed, function()
		vim.schedule(frame_step)
	end)
end

function M.show_help()
	local help_lines = {
		"GitMovie Controls:",
		"j - next commit",
		"h - previous commit",
		"q - quit viewers",
		"g? - show this help",
	}
	render_left(help_lines)
end

return M
