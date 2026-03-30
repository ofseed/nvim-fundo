local M = {}
local cmd = vim.cmd
local api = vim.api

local disposable = require('fundo.lib.disposable')
local manager    = require('fundo.manager')

local enabled

---@type FundoDisposable[]
local disposables = {}

local function createEvents()
    local groupId = api.nvim_create_augroup('Fundo', {})
    api.nvim_create_autocmd('BufReadPost', {
        group = groupId,
        callback = function(t)
            local u = manager:attach(t.buf)
            if u then
                u:check()
            end
        end,
    })
    api.nvim_create_autocmd('BufWritePost', {
        group = groupId,
        callback = function(t)
            local u = manager:get(t.buf)
            if u then
                u:reset(true)
            end
        end,
    })
    api.nvim_create_autocmd('BufWipeout', {
        group = groupId,
        callback = function(t)
            local u = manager:get(t.buf)
            if u then
                u:dispose()
                manager.undos[t.buf] = nil
            end
        end,
    })
    api.nvim_create_autocmd('CmdlineEnter', {
        group = groupId,
        pattern = ':',
        callback = function(t)
            if t.file ~= ':' then
                return
            end
            vim.schedule(function()
                if api.nvim_get_mode().mode == 'c' and vim.fn.getcmdtype() == ':' then
                    manager:syncAll():raise_on_error()
                end
            end)
        end,
    })
    api.nvim_create_autocmd({'VimLeave', 'VimSuspend'}, {
        group = groupId,
        callback = function()
            manager:syncAll(true):raise_on_error()
        end,
    })
    api.nvim_create_autocmd({'TermEnter', 'FocusLost'}, {
        group = groupId,
        callback = function()
            manager:syncAll():raise_on_error()
        end,
    })

    return disposable:create(function()
        api.nvim_del_augroup_by_id(groupId)
    end)
end

local function createCommand()
    cmd([[
        com! FundoEnable lua require('fundo').enable()
        com! FundoDisable lua require('fundo').disable()
    ]])
end

function M.enable()
    if enabled then
        return false
    end
    createCommand()
    disposables = {}
    table.insert(disposables, createEvents())
    table.insert(disposables, manager:initialize())
    enabled = true
    return true
end

function M.disable()
    if not enabled then
        return false
    end
    disposable.disposeAll(disposables)
    enabled = false
    return true
end

return M
