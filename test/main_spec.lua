describe("main", function()
    local nvim
    local lines

    local exec_lua = function(fn, ...)
        return vim.fn.rpcrequest(nvim, "nvim_exec_lua", fn, { ... })
    end

    before_each(function()
        lines = {
            [[<<<<<<< HEAD]],
            [[local value = 5 + 7]],
            [[print(value)]],
            [[print(string.format("value is %d", value))]],
            [[=======]],
            [[local value = 1 - 1]],
            [[>>>>>>> new_branch]],
        }

        nvim = vim.fn.jobstart({ "nvim", "--embed", "--headless" }, { rpc = true })
        exec_lua([[require("conflict-marker").setup()]])
    end)

    after_each(function()
        vim.fn.jobstop(nvim)
    end)

    for _, prepare in ipairs({
        {
            "diff2",
            function()
                lines = {
                    [[<<<<<<< HEAD]],
                    [[local value = 5 + 7]],
                    [[print(value)]],
                    [[print(string.format("value is %d", value))]],
                    [[=======]],
                    [[local value = 1 - 1]],
                    [[>>>>>>> new_branch]],
                }
            end,
        },
        {
            "diff3",
            function()
                lines = {
                    [[<<<<<<< HEAD]],
                    [[local value = 5 + 7]],
                    [[print(value)]],
                    [[print(string.format("value is %d", value))]],
                    [[||||||| 229039e]],
                    [[local value = 1 + 1]],
                    [[=======]],
                    [[local value = 1 - 1]],
                    [[>>>>>>> new_branch]],
                }
            end,
        },
    }) do
        describe("with " .. prepare[1], function()
            before_each(function()
                prepare[2]()
                exec_lua(
                    [[
                        vim.api.nvim_buf_set_lines(0, 0, -1, true, ({...})[1])
                        require("conflict-marker").check()
                    ]],
                    lines
                )
            end)

            it("Conflict ours works", function()
                local result = exec_lua([[
                    vim.cmd("Conflict ours")
                    return vim.api.nvim_buf_get_lines(0, 0, -1, true)
                ]])

                assert.is_same(result, {
                    [[local value = 5 + 7]],
                    [[print(value)]],
                    [[print(string.format("value is %d", value))]],
                })
            end)

            it("Conflict theirs works", function()
                local result = exec_lua([[
                    vim.cmd("Conflict theirs")
                    return vim.api.nvim_buf_get_lines(0, 0, -1, true)
                ]])

                assert.is_same(result, {
                    [[local value = 1 - 1]],
                })
            end)

            it("Conflict both works", function()
                local result = exec_lua([[
                    vim.cmd("Conflict both")
                    return vim.api.nvim_buf_get_lines(0, 0, -1, true)
                ]])

                assert.is_same(result, {
                    [[local value = 5 + 7]],
                    [[print(value)]],
                    [[print(string.format("value is %d", value))]],
                    [[local value = 1 - 1]],
                })
            end)

            it("Conflict none works", function()
                local result = exec_lua([[
                    vim.cmd("Conflict none")
                    return vim.api.nvim_buf_get_lines(0, 0, -1, true)
                ]])

                assert.is_same(result, { "" })
            end)
        end)
    end

    it("selects conflict under cursor", function()
        lines = {
            [[<<<<<<< HEAD]],
            [[ours]],
            [[=======]],
            [[theirs]],
            [[>>>>>>> new_branch]],
            [[<<<<<<< HEAD]],
            [[ours2]],
            [[=======]],
            [[theirs2]],
            [[>>>>>>> new_branch]],
        }

        local result = exec_lua(
            [[
                local lines = ({...})[1]

                vim.api.nvim_buf_set_lines(0, 0, -1, true, lines)
                require("conflict-marker").check()

                vim.api.nvim_win_set_cursor(0, { #lines, 0 })

                vim.cmd("Conflict ours")

                return vim.api.nvim_buf_get_lines(0, 0, -1, true)
            ]],
            lines
        )

        assert.is_same(result, {
            [[<<<<<<< HEAD]],
            [[ours]],
            [[=======]],
            [[theirs]],
            [[>>>>>>> new_branch]],
            [[ours2]],
        })
    end)

    it("does not render labels for a buffer outside a Git repository", function()
        lines = {
            [[<<<<<<< HEAD]],
            [[ours]],
            [[||||||| 229039e]],
            [[base]],
            [[=======]],
            [[theirs]],
            [[>>>>>>> new_branch]],
        }

        local labels = exec_lua(
            [[
                vim.api.nvim_buf_set_lines(0, 0, -1, true, ({...})[1])
                require("conflict-marker").check()

                local ns = vim.api.nvim_get_namespaces()["conflict-marker.nvim/hl"]
                local result = {}
                for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
                    local details = mark[4]
                    if details.virt_lines then
                        table.insert(result, {
                            mark[2],
                            details.virt_lines[1][1][1],
                            details.virt_lines[1][1][2],
                            details.virt_lines_above,
                        })
                    end
                end
                return result
            ]],
            lines
        )

        assert.is_same(labels, {})
    end)

    it("renders commit metadata as one concise line", function()
        local line = exec_lua([[
            local Git = require("conflict-marker.Git")
            return Git.virtual_lines("ours", {
                subject = "fix conflict metadata",
                message = "fix conflict metadata\n\nDetails",
                author = "Alice",
                email = "alice@example.com",
                date = "2026-09-25T12:30:00+08:00",
                hash = "1234567890abcdef",
            })
        ]])

        assert.is_same(line, {
            {
                {
                    "Ours: fix conflict metadata · Alice · 2026-09-25 · 1234567",
                    "ConflictCommit",
                },
            },
        })
    end)
end)
