local git = require("gitmovie.git")

local M = {}

-- Animation state
local S = {
	repo = nil,
	commits = {},
	commit_idx = 0,
	total_commits = 0,
	file_patches = {},
	file_idx = 0,
	buf = nil,
	win = nil,
	status_buf = nil,
	status_win = nil,
	top_buf = nil,
	top_win = nil,
	ns = vim.api.nvim_create_namespace("gitmovie"),
	paused = false,
	cancel = false,
	resume_fn = nil, -- called by resume() to continue paused chain
}

-- Define highlight groups
local function setup_highlights()
	vim.api.nvim_set_hl(0, "GitMovieDel",    { bg = "#4a0e0e", fg = "#ff6b6b", bold = true })
	vim.api.nvim_set_hl(0, "GitMovieAdd",    { bg = "#0d2a0d", fg = "#69ff69", bold = true })
	vim.api.nvim_set_hl(0, "GitMovieStatus", { bg = "#161b22", fg = "#8b949e" })
	vim.api.nvim_set_hl(0, "GitMovieTopBar", { bg = "#0d1117", fg = "#c9d1d9" })
end

-- Open or update the status window at the bottom
local function open_status_window()
	if S.status_buf and vim.api.nvim_buf_is_valid(S.status_buf) then
		return
	end
	S.status_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(S.status_buf, "bufhidden", "wipe")
	S.status_win = vim.api.nvim_open_win(S.status_buf, false, {
		relative = "editor",
		width = vim.o.columns,
		height = 1,
		row = vim.o.lines - 2,
		col = 0,
		style = "minimal",
		focusable = false,
		zindex = 51,
	})
	vim.api.nvim_win_set_option(S.status_win, "winhl", "Normal:GitMovieStatus")
end

local function update_status(text)
	if S.status_buf and vim.api.nvim_buf_is_valid(S.status_buf) then
		vim.api.nvim_buf_set_option(S.status_buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(S.status_buf, 0, -1, false, { text })
		vim.api.nvim_buf_set_option(S.status_buf, "modifiable", false)
	end
end

-- Open (or reuse) the top bar window
local function open_top_bar()
	if S.top_buf and vim.api.nvim_buf_is_valid(S.top_buf) then
		return
	end
	S.top_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[S.top_buf].bufhidden = "wipe"
	S.top_win = vim.api.nvim_open_win(S.top_buf, false, {
		relative = "editor",
		width = vim.o.columns,
		height = 1,
		row = 0,
		col = 0,
		style = "minimal",
		focusable = false,
		zindex = 51,
	})
	vim.wo[S.top_win].winhl = "Normal:GitMovieTopBar"
end

local function update_top_bar(filepath, commit_idx, total_commits)
	if S.top_buf and vim.api.nvim_buf_is_valid(S.top_buf) then
		local text = string.format("  %s  │  Commit %d/%d", filepath, commit_idx, total_commits)
		vim.bo[S.top_buf].modifiable = true
		vim.api.nvim_buf_set_lines(S.top_buf, 0, -1, false, { text })
		vim.bo[S.top_buf].modifiable = false
	end
end

-- Open (or reuse) the main file window
local function open_file_window(filepath, lines)
	-- Create new buffer for this file
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "modifiable", true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	-- Set filetype for syntax highlighting
	local ft = vim.filetype.match({ filename = filepath }) or ""
	if ft ~= "" then
		vim.api.nvim_buf_set_option(buf, "filetype", ft)
	end

	-- Set buffer name
	pcall(vim.api.nvim_buf_set_name, buf, "gitmovie://" .. filepath)

	if S.win and vim.api.nvim_win_is_valid(S.win) then
		-- Reuse existing window, swap buffer
		local old_buf = vim.api.nvim_win_get_buf(S.win)
		vim.api.nvim_win_set_buf(S.win, buf)
		-- Clean up old buffer if it's a gitmovie scratch buf
		if old_buf ~= buf and vim.api.nvim_buf_is_valid(old_buf) then
			pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
		end
	else
		S.win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = vim.o.columns,
			height = vim.o.lines - 3,
			row = 1,
			col = 0,
			zindex = 50,
		})
	end

	vim.wo[S.win].number = true

	S.buf = buf

	-- Buffer-local keymaps
	vim.api.nvim_buf_set_keymap(buf, "n", "q",
		'<cmd>lua require("gitmovie.animator").stop()<CR>',
		{ noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<Space>",
		'<cmd>lua require("gitmovie.animator").toggle_pause()<CR>',
		{ noremap = true, silent = true })
end

-- Highlight specific lines in the buffer
local function highlight_lines(buf, ns, line_nums, hl_group)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	for _, lnum in ipairs(line_nums) do
		vim.api.nvim_buf_add_highlight(buf, ns, hl_group, lnum, 0, -1)
	end
end

-- Highlight lines red, pause, then delete them
-- line_nums: 0-indexed line numbers to delete
-- callback called after deletion
local function highlight_and_delete(buf, ns, line_nums, pause_ms, callback)
	if #line_nums == 0 then
		callback()
		return
	end
	if S.cancel then return end

	highlight_lines(buf, ns, line_nums, "GitMovieDel")

	vim.defer_fn(function()
		if S.cancel then return end
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		-- Delete lines in reverse order to preserve line numbers
		local sorted = vim.deepcopy(line_nums)
		table.sort(sorted, function(a, b) return a > b end)
		for _, lnum in ipairs(sorted) do
			if lnum < vim.api.nvim_buf_line_count(buf) then
				vim.api.nvim_buf_set_lines(buf, lnum, lnum + 1, false, {})
			end
		end
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		callback()
	end, pause_ms)
end

-- Insert lines one at a time (typewriter effect)
-- insert_at: 0-indexed line number to insert before
-- Each line appears after delay_ms
local function typewriter_lines(buf, insert_at, lines, delay_ms, callback)
	if #lines == 0 then
		callback()
		return
	end
	if S.cancel then return end

	local function insert_next(idx, pos)
		if idx > #lines then
			-- Clear add highlights after a short delay
			vim.defer_fn(function()
				vim.api.nvim_buf_clear_namespace(buf, S.ns, 0, -1)
				callback()
			end, 300)
			return
		end
		if S.cancel then return end

		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, pos, pos, false, { lines[idx] })
		vim.api.nvim_buf_set_option(buf, "modifiable", false)

		-- Highlight the new line green
		vim.api.nvim_buf_add_highlight(buf, S.ns, "GitMovieAdd", pos, 0, -1)

		-- Scroll to show inserted line
		if S.win and vim.api.nvim_win_is_valid(S.win) then
			vim.api.nvim_win_set_cursor(S.win, { pos + 1, 0 })
		end

		vim.defer_fn(function()
			insert_next(idx + 1, pos + 1)
		end, delay_ms)
	end

	insert_next(1, insert_at)
end

-- Animate a single diff hunk
-- line_offset: cumulative line delta from prior hunks (deletions removed - additions added)
-- callback(new_offset) called when done
local function animate_hunk(buf, hunk, line_offset, callback)
	if S.cancel then return end

	-- Figure out where deletions are in the current buffer
	-- old_start is 1-indexed in the original file; adjust by line_offset
	local base = hunk.old_start - 1 + line_offset -- 0-indexed in current buffer

	-- Walk through hunk lines to find deletion positions and addition texts
	local del_positions = {}
	local add_texts = {}
	local add_insert_at = base -- where to insert additions after deletions are removed

	local cursor = base
	for _, entry in ipairs(hunk.lines) do
		if entry.op == " " then
			cursor = cursor + 1
		elseif entry.op == "-" then
			table.insert(del_positions, cursor)
			cursor = cursor + 1
		elseif entry.op == "+" then
			table.insert(add_texts, entry.text)
		end
	end

	-- The insertion point for additions is right after context lines before first deletion
	-- Recalculate: find the first non-context line position
	add_insert_at = base
	for _, entry in ipairs(hunk.lines) do
		if entry.op == " " then
			add_insert_at = add_insert_at + 1
		else
			break
		end
	end

	local dels = #del_positions
	local adds = #add_texts
	local delta = adds - dels

	highlight_and_delete(buf, S.ns, del_positions, 800, function()
		if S.cancel then return end
		-- After deletions, additions insert at add_insert_at (which is now correct
		-- since deleted lines are gone)
		typewriter_lines(buf, add_insert_at, add_texts, 120, function()
			callback(line_offset + delta)
		end)
	end)
end

-- Animate all hunks in a file patch sequentially
local function animate_file_patch(patch, patch_num, total_patches, callback)
	if S.cancel then return end

	-- Get file content at parent commit (hash^ means parent)
	local parent_ref = S.commits[S.commit_idx].hash .. "^"
	local lines
	if patch.is_new then
		lines = {}
	else
		lines = git.get_file_at(S.repo, parent_ref, patch.filepath)
	end

	-- Open file buffer with parent content
	open_file_window(patch.filepath, lines)

	-- Update status bar
	local c = S.commits[S.commit_idx]
	-- Build progress bar
	local filled = math.floor((S.commit_idx / S.total_commits) * 16)
	local bar = string.rep("█", filled) .. string.rep("░", 16 - filled)
	update_status(string.format(
		"  [%s]  Commit %d/%d  %s  %s  │  File %d/%d: %s  │  <Space> pause  q quit",
		bar,
		S.commit_idx, S.total_commits,
		c.hash:sub(1, 7), c.subject,
		patch_num, total_patches,
		patch.filepath
	))
	update_top_bar(patch.filepath, S.commit_idx, S.total_commits)

	if #patch.hunks == 0 then
		-- No hunks (e.g. binary file or deleted file with no content diff)
		vim.defer_fn(callback, 1000)
		return
	end

	-- Animate hunks sequentially with callback chain
	local function do_hunk(idx, offset)
		if S.cancel then return end
		if idx > #patch.hunks then
			-- Done with this file, pause before moving on
			vim.defer_fn(callback, 1600)
			return
		end

		if S.paused then
			S.resume_fn = function()
				do_hunk(idx, offset)
			end
			return
		end

		animate_hunk(S.buf, patch.hunks[idx], offset, function(new_offset)
			do_hunk(idx + 1, new_offset)
		end)
	end

	do_hunk(1, 0)
end

-- Animate a single commit (all its file patches)
local function animate_commit(callback)
	if S.cancel then return end
	if S.paused then
		S.resume_fn = function()
			animate_commit(callback)
		end
		return
	end

	if S.commit_idx > #S.commits then
		-- Movie finished
		update_status("GitMovie: replay finished  |  q quit")
		return
	end

	local c = S.commits[S.commit_idx]

	-- Get and parse the diff for this commit
	local diff_text = vim.fn.system({
		"git", "-C", S.repo, "show", c.hash
	})

	local patches = git.parse_diff(diff_text)

	-- Filter to only files with actual hunks (skip binary/empty)
	local file_patches = {}
	for _, p in ipairs(patches) do
		if #p.hunks > 0 or p.is_new or p.is_deleted then
			table.insert(file_patches, p)
		end
	end

	if #file_patches == 0 then
		-- Skip this commit (no text changes)
		S.commit_idx = S.commit_idx + 1
		animate_commit(callback)
		return
	end

	-- Animate each file patch sequentially
	local function do_patch(idx)
		if S.cancel then return end
		if idx > #file_patches then
			-- Move to next commit
			S.commit_idx = S.commit_idx + 1
			animate_commit(callback)
			return
		end

		if S.paused then
			S.resume_fn = function()
				do_patch(idx)
			end
			return
		end

		animate_file_patch(file_patches[idx], idx, #file_patches, function()
			do_patch(idx + 1)
		end)
	end

	do_patch(1)
end

-- Public: start playing from a given commit index
function M.play_from(repo, commits, start_idx)
	M.stop() -- clean up any existing state

	setup_highlights()

	S.repo = repo
	S.commits = commits
	S.commit_idx = start_idx
	S.total_commits = #commits
	S.paused = false
	S.cancel = false
	S.resume_fn = nil

	open_status_window()
	open_top_bar()
	update_status(string.format(
		"GitMovie: loading commit %d/%d...",
		start_idx, #commits
	))

	-- Kick off the animation chain
	vim.schedule(function()
		animate_commit(function() end)
	end)
end

-- Public: stop animation and close all windows
function M.stop()
	S.cancel = true
	S.paused = false
	S.resume_fn = nil

	if S.win and vim.api.nvim_win_is_valid(S.win) then
		vim.api.nvim_win_close(S.win, true)
	end
	S.win = nil
	S.buf = nil

	if S.status_win and vim.api.nvim_win_is_valid(S.status_win) then
		vim.api.nvim_win_close(S.status_win, true)
	end
	S.status_win = nil
	S.status_buf = nil

	if S.top_win and vim.api.nvim_win_is_valid(S.top_win) then
		vim.api.nvim_win_close(S.top_win, true)
	end
	S.top_win = nil
	S.top_buf = nil

	S.commits = {}
	S.commit_idx = 0
end

-- Public: pause animation
function M.pause()
	S.paused = true
	update_status("GitMovie: PAUSED  |  <Space> resume  q quit")
end

-- Public: resume animation
function M.resume()
	if not S.paused then return end
	S.paused = false
	if S.resume_fn then
		local fn = S.resume_fn
		S.resume_fn = nil
		vim.schedule(fn)
	end
end

-- Public: toggle pause/resume
function M.toggle_pause()
	if S.paused then
		M.resume()
	else
		M.pause()
	end
end

return M
