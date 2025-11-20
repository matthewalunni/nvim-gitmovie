local M = {}
M.repo = nil
M.speed = 100 -- ms per frame
M.timer = nil
M.diff_buf = nil
M.diff_win = nil
M.ns = vim.api.nvim_create_namespace("gitmovie")

-- Ensure a floating window is ready to display frames
local function ensure_window()
	if M.diff_win and vim.api.nvim_win_is_valid(M.diff_win) then
		vim.api.nvim_set_current_win(M.diff_win)
		return
	end
	local buf = vim.api.nvim_create_buf(false, true)
	local width = math.floor(vim.o.columns * 0.9)
	local height = math.floor(vim.o.lines * 0.8)
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
	})
	M.diff_buf = buf
	M.diff_win = win
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "filetype", "gitmovie")
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
end

-- Build commits list (oldest first)
local function build_commits(repo)
	local cmd = { "git", "-C", repo, "log", "--reverse", "--pretty=format:%H" }
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
		-- skip header lines
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

local function render(lines)
	ensure_window()
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
end

function M.start(repo_path)
	repo_path = repo_path or vim.fn.getcwd()
	if not repo_path or repo_path == "" then
		vim.notify("GitMovie: please specify a repo path", vim.log.levels.ERROR)
		return
	end
	local commits = build_commits(repo_path)
	if vim.tbl_isempty(commits) then
		vim.notify("GitMovie: no commits found", vim.log.levels.ERROR)
		return
	end
	M._commits = commits
	M._index = 1
	M.repo = repo_path
	M.stop() -- ensure clean
	ensure_window()
	M.timer = vim.loop.new_timer()
	local function frame_step()
		if not M._commits or M._index > #M._commits then
			M.stop()
			vim.notify("GitMovie: replay finished")
			return
		end
		local hash = M._commits[M._index]
		local subject = vim.fn.system({ "git", "-C", repo_path, "log", "-1", "--pretty=format:%s", hash })
		local header = string.format("Commit: %s - %s", hash, subject:gsub("\n", " "))
		local diff = diff_lines(repo_path, hash)
		local frame = {}
		table.insert(frame, header)
		for _, ln in ipairs(diff) do
			table.insert(frame, ln)
		end
		render(frame)
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

return M
