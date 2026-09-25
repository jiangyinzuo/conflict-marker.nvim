local M = {}
local const = require("conflict-marker.const")

local function trim(value)
    return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function split_lines(value)
    local result = {}
    for line in vim.gsplit(value or "", "\n", { plain = true, trimempty = true }) do
        table.insert(result, line)
    end
    return result
end

local function run_git(cwd, args)
    local command = { "git", "-C", cwd }
    vim.list_extend(command, args)

    local result = vim.system(command, { text = true }):wait()
    if result.code ~= 0 then
        return nil
    end
    return result.stdout or ""
end

local function first_line(value)
    return split_lines(value)[1]
end

local function resolve_ref(cwd, ref)
    local value = first_line(run_git(cwd, { "rev-parse", "--verify", ref }))
    if value and value:match("^[0-9a-fA-F]+$") then
        return value
    end
end

local function ref_file(cwd, name)
    local path = first_line(run_git(cwd, { "rev-parse", "--git-path", name }))
    if not path then
        return
    end

    if path:sub(1, 1) ~= "/" then
        path = cwd .. "/" .. path
    end
    local ok, lines = pcall(vim.fn.readfile, path)
    if ok then
        return lines
    end
end

local function ref_file_hash(cwd, name)
    local lines = ref_file(cwd, name)
    if not lines then
        return
    end
    for _, line in ipairs(lines) do
        local hash = line:match("^%s*([0-9a-fA-F]+)%s*$")
        if hash then
            return hash
        end
    end
end

local function repository(filename)
    if filename == "" then
        return
    end

    local directory = vim.fn.fnamemodify(filename, ":h")
    local root = first_line(run_git(directory, { "rev-parse", "--show-toplevel" }))
    if not root then
        return
    end

    local prefix = root
    if prefix:sub(-1) ~= "/" then
        prefix = prefix .. "/"
    end
    if filename:sub(1, #prefix) ~= prefix then
        return
    end

    return root, filename:sub(#prefix + 1)
end

local function index_stages(cwd, path)
    local output = run_git(cwd, { "ls-files", "--unmerged", "-z", "--", path })
    if not output then
        return {}
    end

    local stages = {}
    for entry in vim.gsplit(output, "\0", { plain = true, trimempty = true }) do
        local mode, blob, stage = entry:match("^(%d+) (%x+) (%d)\t")
        if mode and blob and stage then
            stages[tonumber(stage)] = blob
        end
    end
    return stages
end

local function commit_has_blob(cwd, commit, path, blob)
    if not commit or not blob then
        return false
    end
    local value = first_line(run_git(cwd, { "rev-parse", commit .. ":" .. path }))
    return value == blob
end

local function find_commit_for_blob(cwd, path, blob)
    if not blob then
        return
    end
    return first_line(run_git(cwd, {
        "log",
        "--all",
        "--format=%H",
        "--find-object=" .. blob,
        "--",
        path,
    }))
end

local function commit_parent(cwd, commit, parent)
    if not commit then
        return
    end
    return first_line(run_git(cwd, { "rev-parse", commit .. "^" .. (parent or 1) }))
end

local function commit_metadata(cwd, commit)
    if not commit then
        return
    end

    local output = run_git(cwd, {
        "show",
        "-s",
        "--format=%H%x00%an%x00%ae%x00%cI%x00%s",
        commit,
    })
    local fields = {}
    if output then
        for field in vim.gsplit(output, "\0", { plain = true, trimempty = true }) do
            table.insert(fields, field)
        end
    end
    if #fields < 5 then
        return
    end

    local message = trim(run_git(cwd, { "show", "-s", "--format=%B", commit }))
    return {
        hash = fields[1],
        author = fields[2],
        email = fields[3],
        date = fields[4],
        message = message ~= "" and message or fields[5],
        subject = fields[5],
    }
end

local function candidate_commit(cwd, path, blob, candidates)
    for _, candidate in ipairs(candidates) do
        if commit_has_blob(cwd, candidate, path, blob) then
            return candidate
        end
    end
    return find_commit_for_blob(cwd, path, blob)
end

local function merge_base(cwd, left, right)
    return first_line(run_git(cwd, { "merge-base", left, right }))
end

local function merge_base_many(cwd, commits)
    if #commits < 2 then
        return
    end
    local args = { "merge-base", "--octopus" }
    vim.list_extend(args, commits)
    return first_line(run_git(cwd, args))
end

local function sequencer_mainline(cwd)
    for _, line in ipairs(ref_file(cwd, "sequencer/opts") or {}) do
        local parent = line:match("^mainline%s+(%d+)$")
        if parent then
            return tonumber(parent)
        end
    end
end

local function conflict_refs(cwd)
    local head = resolve_ref(cwd, "HEAD")
    local merge_heads = ref_file(cwd, "MERGE_HEAD") or {}
    local merge_commits = {}
    for _, line in ipairs(merge_heads) do
        local commit = line:match("^%s*([0-9a-fA-F]+)")
        if commit then
            table.insert(merge_commits, commit)
        end
    end
    if #merge_commits > 0 then
        return {
            ours = head,
            theirs = merge_commits[1],
            theirs_candidates = merge_commits,
            base = merge_base_many(cwd, vim.list_extend({ head }, merge_commits))
                or merge_base(cwd, head, merge_commits[1]),
        }
    end

    local cherry_pick = resolve_ref(cwd, "CHERRY_PICK_HEAD")
    if cherry_pick then
        local mainline = sequencer_mainline(cwd)
        return {
            ours = head,
            theirs = cherry_pick,
            base = commit_parent(cwd, cherry_pick, mainline),
        }
    end

    local revert = resolve_ref(cwd, "REVERT_HEAD")
    if revert then
        local mainline = sequencer_mainline(cwd)
        return {
            ours = head,
            theirs = commit_parent(cwd, revert, mainline),
            base = revert,
        }
    end

    local rebase = resolve_ref(cwd, "REBASE_HEAD") or ref_file_hash(cwd, "rebase-merge/stopped-sha")
    if rebase then
        return {
            ours = head,
            theirs = rebase,
            base = commit_parent(cwd, rebase),
        }
    end

    local applied = ref_file_hash(cwd, "rebase-apply/original-commit")
    if applied then
        return {
            ours = head,
            theirs = applied,
            base = commit_parent(cwd, applied),
        }
    end

    return { ours = head }
end

---@param bufnr integer
---@return table<string, table>?
function M.get_conflict_commits(bufnr)
    local filename = vim.api.nvim_buf_get_name(bufnr)
    local root, path = repository(filename)
    if not root then
        return nil, false
    end

    local stages = index_stages(root, path)
    local refs = conflict_refs(root)
    local result = {}
    local candidates = {
        ours = { refs.ours },
        base = { refs.base, refs.theirs and commit_parent(root, refs.theirs) },
        theirs = refs.theirs_candidates or { refs.theirs },
    }

    -- Git's unmerged index stages are stable across merge-like operations:
    -- stage 1 is the common ancestor, stage 2 ours, and stage 3 theirs.
    for role, stage in pairs({ ours = 2, base = 1, theirs = 3 }) do
        local commit = candidate_commit(root, path, stages[stage], candidates[role])
        if not commit and role == "base" then
            -- Recursive merges may produce a virtual base blob without a
            -- commit of its own; retain the operation's base as context.
            commit = candidates.base[1]
        end
        local metadata = commit_metadata(root, commit)
        if metadata then
            result[role] = metadata
        end
    end

    if next(result) == nil then
        return nil, true
    end
    return result, true
end

---@param role string
---@param commit table
---@return table
function M.virtual_lines(role, commit)
    local role_name = role:sub(1, 1):upper() .. role:sub(2)
    local subject = (commit.subject or commit.message or ""):match("^[^\r\n]*")
    local date = (commit.date or ""):sub(1, 10)
    local hash = (commit.hash or ""):sub(1, 7)
    return {
        {
            {
                string.format("%s: %s · %s · %s · %s", role_name, subject, commit.author, date, hash),
                const.HL_CONFLICT_COMMIT,
            },
        },
    }
end

return M
