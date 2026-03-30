local git = require("gitflix.git")

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
	ns = vim.api.nvim_create_namespace("gitflix"),
	paused = false,
	cancel = false,
	resume_fn = nil, -- called by resume() to continue paused chain
	direction = 1, -- 1 = forward, -1 = reverse
}

-- Define highlight groups
local function setup_highlights()
	vim.api.nvim_set_hl(0, "GitFlixDel",    { bg = "#4a0e0e", fg = "#ff6b6b", bold = true })
	vim.api.nvim_set_hl(0, "GitFlixAdd",    { bg = "#0d2a0d", fg = "#69ff69", bold = true })
	vim.api.nvim_set_hl(0, "GitFlixStatus", { bg = "#161b22", fg = "#8b949e" })
	vim.api.nvim_set_hl(0, "GitFlixTopBar", { bg = "#0d1117", fg = "#c9d1d9" })
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
	vim.api.nvim_win_set_option(S.status_win, "winhl", "Normal:GitFlixStatus")
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
	vim.wo[S.top_win].winhl = "Normal:GitFlixTopBar"
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
	pcall(vim.api.nvim_buf_set_name, buf, "gitflix://" .. filepath)

	if S.win and vim.api.nvim_win_is_valid(S.win) then
		-- Reuse existing window, swap buffer
		local old_buf = vim.api.nvim_win_get_buf(S.win)
		vim.api.nvim_win_set_buf(S.win, buf)
		-- Clean up old buffer if it's a gitflix scratch buf
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
		'<cmd>lua require("gitflix.animator").stop()<CR>',
		{ noremap = true, silent = true })
	vim.api.nvim_buf_set_keymap(buf, "n", "<Space>",
		'<cmd>lua require("gitflix.animator").toggle_pause()<CR>',
		{ noremap = true, silent = true })
end

-- Highlight specific lines in the buffer
local function highlight_lines(buf, ns, line_nums, hl_group)
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	for _, lnum in ipairs(line_nums) do
		vim.api.nvim_buf_set_extmark(buf, ns, lnum, 0, { line_hl_group = hl_group })
	end
end

-- Highlight lines red, pause, then delete them one at a time (bottom-to-top).
-- line_nums: 0-indexed line numbers to delete
-- callback(actual_dels) called after deletion with the count of lines actually removed
local function highlight_and_delete(buf, ns, line_nums, pause_ms, callback)
	if #line_nums == 0 then
		callback(0)
		return
	end
	if S.cancel then return end

	highlight_lines(buf, ns, line_nums, "GitFlixDel")

	-- After the initial pause (user sees the red highlights), delete lines
	-- one by one from bottom to top so each removal is individually visible.
	-- Adapt the per-line delay so total deletion time stays around 1.2s.
	local sorted = vim.deepcopy(line_nums)
	table.sort(sorted, function(a, b) return a > b end)
	local del_delay = math.max(150, math.min(400, math.floor(2400 / #sorted)))

	vim.defer_fn(function()
		if S.cancel then return end
		if S.paused then
			S.resume_fn = function() highlight_and_delete(buf, ns, line_nums, 0, callback) end
			return
		end
		local actual_dels = 0

		local function delete_next(idx)
			if S.cancel then return end
			if S.paused then
				S.resume_fn = function() delete_next(idx) end
				return
			end
			if idx > #sorted then
				vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
				vim.defer_fn(function()
					callback(actual_dels)
				end, 250)
				return
			end
			local lnum = sorted[idx]
			vim.api.nvim_buf_set_option(buf, "modifiable", true)
			if lnum < vim.api.nvim_buf_line_count(buf) then
				vim.api.nvim_buf_set_lines(buf, lnum, lnum + 1, false, {})
				actual_dels = actual_dels + 1
			end
			vim.api.nvim_buf_set_option(buf, "modifiable", false)
			vim.defer_fn(function()
				delete_next(idx + 1)
			end, del_delay)
		end

		delete_next(1)
	end, pause_ms)
end

-- Insert lines character by character (typing effect)
-- insert_at: 0-indexed line number to insert before
local function typewriter_lines(buf, insert_at, lines, _delay_ms, callback)
	if #lines == 0 then
		callback()
		return
	end
	if S.cancel then return end

	local char_delay = 15 -- ms per character

	local function type_chars(line_str, char_idx, buf_line_pos, on_done)
		if S.cancel then return end
		if S.paused then
			S.resume_fn = function() type_chars(line_str, char_idx, buf_line_pos, on_done) end
			return
		end
		if char_idx > #line_str then
			on_done()
			return
		end
		local partial = line_str:sub(1, char_idx)
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, buf_line_pos, buf_line_pos + 1, false, { partial })
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		vim.api.nvim_buf_set_extmark(buf, S.ns, buf_line_pos, 0, { line_hl_group = "GitFlixAdd" })
		if S.win and vim.api.nvim_win_is_valid(S.win) then
			vim.api.nvim_win_set_cursor(S.win, { buf_line_pos + 1, char_idx })
		end
		vim.defer_fn(function()
			type_chars(line_str, char_idx + 1, buf_line_pos, on_done)
		end, char_delay)
	end

	local function insert_next(idx, pos)
		if S.cancel then return end
		if S.paused then
			S.resume_fn = function() insert_next(idx, pos) end
			return
		end
		if idx > #lines then
			vim.defer_fn(function()
				vim.api.nvim_buf_clear_namespace(buf, S.ns, 0, -1)
				callback()
			end, 300)
			return
		end

		-- Insert empty line first, then fill it character by character
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
		vim.api.nvim_buf_set_lines(buf, pos, pos, false, { "" })
		vim.api.nvim_buf_set_option(buf, "modifiable", false)
		vim.api.nvim_buf_set_extmark(buf, S.ns, pos, 0, { line_hl_group = "GitFlixAdd" })
		if S.win and vim.api.nvim_win_is_valid(S.win) then
			vim.api.nvim_win_set_cursor(S.win, { pos + 1, 0 })
		end

		local line_str = lines[idx]
		if #line_str == 0 then
			vim.defer_fn(function()
				insert_next(idx + 1, pos + 1)
			end, char_delay)
		else
			type_chars(line_str, 1, pos, function()
				vim.defer_fn(function()
					insert_next(idx + 1, pos + 1)
				end, char_delay)
			end)
		end
	end

	insert_next(1, insert_at)
end

-- Animate a single diff hunk
-- line_offset: cumulative line delta from prior hunks (deletions removed - additions added)
-- callback(new_offset) called when done
local function animate_hunk(buf, hunk, line_offset, callback)
	if S.cancel then return end

	-- old_start is 1-indexed; convert to 0-indexed and adjust by accumulated offset
	-- Clamp to 0 for new-file hunks where old_start=0 produces base=-1
	local base = math.max(0, hunk.old_start - 1 + line_offset)

	-- Walk the hunk to collect:
	--   del_positions  : 0-indexed buffer lines to delete
	--   add_groups     : { pos, texts } pairs — pos is the post-deletion insertion
	--                    point, calculated as base + (# context lines seen so far)
	local del_positions = {}
	local add_groups    = {}
	local pending_adds  = {}
	local old_cursor    = base
	local ctx_count     = 0   -- context lines seen before current position

	local function flush_adds()
		if #pending_adds > 0 then
			table.insert(add_groups, { pos = base + ctx_count, texts = pending_adds })
			pending_adds = {}
		end
	end

	for _, entry in ipairs(hunk.lines) do
		if entry.op == " " then
			flush_adds()
			ctx_count   = ctx_count + 1
			old_cursor  = old_cursor + 1
		elseif entry.op == "-" then
			flush_adds()
			table.insert(del_positions, old_cursor)
			old_cursor = old_cursor + 1
		elseif entry.op == "+" then
			table.insert(pending_adds, entry.text)
		end
	end
	flush_adds()

	local adds  = 0
	for _, g in ipairs(add_groups) do adds = adds + #g.texts end

	highlight_and_delete(buf, S.ns, del_positions, 1500, function(actual_dels)
		if S.cancel then return end
		-- delta uses the actual deletion count so line_offset stays accurate
		-- even if the bounds check skipped any out-of-range deletions.
		local delta = adds - actual_dels
		-- Insert each addition group at its correct position, adjusting for
		-- lines already inserted by prior groups in this hunk.
		local insert_offset = 0
		local function do_group(gi)
			if gi > #add_groups then
				callback(line_offset + delta)
				return
			end
			local g = add_groups[gi]
			typewriter_lines(buf, g.pos + insert_offset, g.texts, 120, function()
				insert_offset = insert_offset + #g.texts
				do_group(gi + 1)
			end)
		end
		do_group(1)
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
		lines = git.get_file_at(S.repo, parent_ref, patch.old_filepath or patch.filepath)
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
		update_status("GitFlix: replay finished  |  q quit")
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
function M.play_from(repo, commits, start_idx, direction)
	M.stop() -- clean up any existing state

	setup_highlights()

	S.repo = repo
	S.commits = commits
	S.commit_idx = start_idx
	S.total_commits = #commits
	S.paused = false
	S.cancel = false
	S.resume_fn = nil
	S.direction = direction or 1

	open_status_window()
	open_top_bar()
	update_status(string.format(
		"GitFlix: loading commit %d/%d...",
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
	update_status("GitFlix: PAUSED  |  <Space> resume  q quit")
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
