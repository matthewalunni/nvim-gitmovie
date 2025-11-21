local M = {}
M.repo = nil
M.speed = 3000 -- ms per frame
M.timer = nil
M.diff_buf = nil
M.diff_win = nil
M.left_buf = nil
M.left_win = nil
M.ns = vim.api.nvim_create_namespace("gitmovie")

-- track commits and positions
M._commits = {}
M._index = 1 -- next-to-show index when playing
M._current = 0 -- last shown index
M._mapped = false

-- Ensure a full-screen window with left and right panes is ready
local function ensure_window()
	if M.diff_win and vim.api.nvim_win_is_valid(M.diff_win) and 
	   M.left_win and vim.api.nvim_win_is_valid(M.left_win) then
		vim.api.nvim_set_current_win(M.diff_win)
		return
	end
	
	-- Create left buffer (25% width)
	local left_buf = vim.api.nvim_create_buf(false, true)
	local left_width = math.floor(vim.o.columns * 0.25)
	local left_win = vim.api.nvim_open_win(left_buf, true, {
		relative = "editor",
		width = left_width,
		height = vim.o.lines - 2,
		row = 0,
		col = 0,
		style = "minimal",
	})
	
	-- Create right buffer (75% width)
	local right_buf = vim.api.nvim_create_buf(false, true)
	local right_width = vim.o.columns - left_width
	local right_win = vim.api.nvim_open_win(right_buf, true, {
		relative = "editor",
		width = right_width,
		height = vim.o.lines - 2,
		row = 0,
		col = left_width,
		style = "minimal",
	})
	
	M.left_buf = left_buf
	M.left_win = left_win
	M.diff_buf = right_buf
	M.diff_win = right_win
	
	-- Set buffer options for both panes
	for _, buf in ipairs({left_buf, right_buf}) do
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
		vim.api.nvim_buf_set_option(buf, "filetype", "gitmovie")
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
	end

	-- buffer-local mappings for navigation: use counts like 3l or 2h
	if not M._mapped then
		for _, buf in ipairs({left_buf, right_buf}) do
			vim.api.nvim_buf_set_keymap(
				buf,
				"n",
				"l",
				'<cmd>lua require("gitmovie")._on_nav(vim.v.count1)<CR>',
				{ noremap = true, silent = true }
			)
			vim.api.nvim_buf_set_keymap(
				buf,
				"n",
				"h",
				'<cmd>lua require("gitmovie")._on_nav(-vim.v.count1)<CR>',
				{ noremap = true, silent = true }
			)
			vim.api.nvim_buf_set_keymap(
				buf,
				"n",
				"q",
				'<cmd>lua require("gitmovie").stop()<CR>',
				{ noremap = true, silent = true }
			)
		end
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
		if s ~= "" then
			table.insert(lines, s)
		end
	end
	return lines
end

-- Get diff lines for a commit (filter headers, return relevant lines)
local function diff_lines(repo, hash)
	local cmd = { "git", "-C", repo, "show", "--unified=4", hash }
	local out = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return {}
	end
	local lines = {}
	for line in string.gmatch(out, "[^\n]+") do
		if line:match("^diff ") or line:match("^index ") or line:match("^---") or line:match("^+++") then
		else
			local l = line
			if l == "" then
				l = " "
			end
			table.insert(lines, l)
		end
	end
	return lines
end

local function render_right(lines)
	vim.api.nvim_buf_set_lines(M.diff_buf, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(M.diff_buf, M.ns, 0, -1)
	for i, l in ipairs(lines) do
		local hl = nil
		if l:sub(1, 1) == "+" then
			hl = "GitMovieAdd"
		elseif l:sub(1, 1) == "-" then
			hl = "GitMovieDel"
		else
			hl = "GitMovieCtx"
		end
		if hl then
			vim.api.nvim_buf_add_highlight(M.diff_buf, M.ns, hl, i - 1, 0, -1)
		end
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
	if date_str ~= "" then
		date_str = date_str:gsub("\n", " ")
	end
	table.insert(left_lines, "Date: " .. date_str)
	table.insert(left_lines, "")
	table.insert(left_lines, "Changes:")
	if changes and #changes > 0 then
		for _, c in ipairs(changes) do
			table.insert(left_lines, "  " .. c)
		end
	end
	render_left(left_lines)
end

function M._show_index(idx)
	if not M._commits or #M._commits == 0 then
		return
	end
	if idx < 1 then
		idx = 1
	end
	if idx > #M._commits then
		idx = #M._commits
	end
	local hash = M._commits[idx]
	local subject = vim.fn.system({ "git", "-C", M.repo, "log", "-1", "--pretty=format:%s", hash })
	local header = string.format("Commit: %s - %s", hash, subject:gsub("\\n", " "))
	local diff = diff_lines(M.repo, hash)
	local right_frame = {}
	table.insert(right_frame, header)
	for _, ln in ipairs(diff) do
		table.insert(right_frame, ln)
	end
	render_right(right_frame)
	M._current = idx
	M._index = math.min(#M._commits, M._current + 1)

	-- Update left meta pane
	local date = vim.fn.system({ "git", "-C", M.repo, "log", "-1", "--format=%ad", "--date=short", hash })
	local changes = {}
	local ch_out = vim.fn.system({ "git", "-C", M.repo, "diff-tree", "--no-commit-id", "--name-status", "-r", hash })
	if vim.v.shell_error == 0 and ch_out and ch_out ~= "" then
		for s in string.gmatch(ch_out, "[^\\n]+") do
			if s ~= "" then
				table.insert(changes, s)
			end
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
	if newidx < 1 then
		newidx = 1
	end
	if newidx > #M._commits then
		newidx = #M._commits
	end
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
		pcall(function()
			M.timer:stop()
		end)
		M.timer = nil
	end
	if M.diff_win and vim.api.nvim_win_is_valid(M.diff_win) then
		vim.api.nvim_win_close(M.diff_win, true)
		M.diff_win = nil
	end
	if M.left_win and vim.api.nvim_win_is_valid(M.left_win) then
		vim.api.nvim_win_close(M.left_win, true)
		M.left_win = nil
	end
	M._commits = {}
	M._index = 1
	M._current = 0
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
	ensure_window()
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
		local frame = {}
		table.insert(frame, header)
		for _, ln in ipairs(diff) do
			table.insert(frame, ln)
		end
		render_right(frame)
		M._current = idx
		M._index = M._index + 1
		if M._index > #M._commits then
			vim.defer_fn(function()
				M.stop()
			end, 400)
		end
	end
	M.timer:start(0, M.speed, function()
		vim.schedule(frame_step)
	end)
end

function M.open_movie_player()
	-- open the right and left panes side by side
	ensure_window()
	-- render left and right below
	render_left({ "GitMovie Player", "", "Use 'h' and 'l' to navigate commits.", "Press 'q' to quit." })
	render_right({ "GitMovie Player", "", "Use 'h' and 'l' to navigate commits.", "Press 'q' to quit." })
end

return M
