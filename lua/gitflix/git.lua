local M = {}

-- Get all commits oldest-first with hash, subject, date
-- Returns: { {hash, subject, date}, ... }
function M.get_commits(repo)
	local out = vim.fn.system({
		"git", "-C", repo,
		"log", "--reverse", "HEAD",
		"--format=%H|%s|%ad",
		"--date=short",
	})
	if vim.v.shell_error ~= 0 then
		vim.notify("GitFlix: failed to read commits", vim.log.levels.ERROR)
		return {}
	end
	local commits = {}
	for line in out:gmatch("[^\n]+") do
		if line ~= "" then
			local hash, subject, date = line:match("^([^|]+)|([^|]*)|(.*)$")
			if hash then
				table.insert(commits, { hash = hash, subject = subject, date = date })
			end
		end
	end
	return commits
end

-- Get file content at a specific commit
-- Returns list of lines, or {} if file doesn't exist at that commit
function M.get_file_at(repo, hash_ref, filepath)
	local out = vim.fn.system({
		"git", "-C", repo,
		"show", hash_ref .. ":" .. filepath,
	})
	if vim.v.shell_error ~= 0 then
		return {}
	end
	local lines = {}
	for line in out:gmatch("[^\n]*") do
		table.insert(lines, line)
	end
	-- Remove trailing empty line that gmatch adds
	if lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

-- Parse unified diff output from `git show <hash>` into structured file patches
-- Returns: { {filepath, is_new, is_deleted, hunks={...}}, ... }
function M.parse_diff(diff_text)
	local patches = {}
	local current_patch = nil
	local current_hunk = nil

	for line in diff_text:gmatch("[^\n]*\n?") do
		-- Remove trailing newline for matching
		local l = line:gsub("\n$", "")

		-- New file section
		local b_path = l:match("^diff %-%-git a/.+ b/(.+)$")
		if b_path then
			current_hunk = nil
			current_patch = {
				filepath = b_path,
				is_new = false,
				is_deleted = false,
				hunks = {},
			}
			table.insert(patches, current_patch)
		elseif l:match("^new file mode") then
			if current_patch then
				current_patch.is_new = true
			end
		elseif l:match("^deleted file mode") then
			if current_patch then
				current_patch.is_deleted = true
			end
		elseif l:match("^%-%-%- ") then
			local old_file = l:match("^%-%-%- a/(.+)$")
			if old_file and current_patch then
				current_patch.old_filepath = old_file
			end
		elseif l:match("^%+%+%+ ") then
			-- Skip +++ header lines
		elseif current_patch then
			-- Hunk header: @@ -old_start[,old_count] +new_start[,new_count] @@
			local old_start, old_count, new_start, new_count =
				l:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
			if old_start then
				current_hunk = {
					old_start = tonumber(old_start),
					old_count = tonumber(old_count ~= "" and old_count or "1"),
					new_start = tonumber(new_start),
					new_count = tonumber(new_count ~= "" and new_count or "1"),
					lines = {},
				}
				table.insert(current_patch.hunks, current_hunk)
			elseif current_hunk then
				-- Content line
				if l:sub(1, 1) == "+" then
					table.insert(current_hunk.lines, { op = "+", text = l:sub(2) })
				elseif l:sub(1, 1) == "-" then
					table.insert(current_hunk.lines, { op = "-", text = l:sub(2) })
				elseif l:sub(1, 1) == " " then
					table.insert(current_hunk.lines, { op = " ", text = l:sub(2) })
				elseif l == "\\ No newline at end of file" then
					-- skip
				end
			end
		end
	end

	return patches
end

return M
