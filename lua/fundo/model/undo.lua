local api = vim.api
local fn = vim.fn
local cmd = vim.cmd
local uv = vim.loop

local async = require('async')
local path = require('fundo.fs.path')

---@class FundoUndo
---@field dir string
---@field bufnr number
---@field attached boolean
local Undo = {}

local function awaitFs(argc, op, ...)
    local err, result = async.await(argc, op, ...)
    if err then
        error(err, 0)
    end
    return result
end

function Undo:new(bufnr, dir)
    local o = setmetatable({}, self)
    self.__index = self
    o.bufnr = bufnr
    o.dir = dir
    return o
end

function Undo:attach()
    local bt = vim.bo[self.bufnr].bt
    local name = api.nvim_buf_get_name(self.bufnr)
    if path.dirname(name) == self.dir then
        vim.bo[self.bufnr].undofile = false
    end
    self.attached = (bt == '' or bt == 'acwrite') and vim.bo[self.bufnr].undofile
    if self.attached then
        self:reset()
    end
    return self.attached
end

function Undo:dispose()
    self.attached = false
end

---
---@param dirty? boolean
---@param bufName? string
function Undo:reset(dirty, bufName)
    if not self.attached then
        return
    end
    local name = bufName or api.nvim_buf_get_name(self.bufnr)
    if name ~= self.name then
        self.undoPath = fn.undofile(name)
        local basename = path.basename(self.undoPath)
        self.fallbackPath = path.join(self.dir, basename)
    end
    self.name = name
    self.isDirty = dirty and self.undoPath ~= '' and vim.bo[self.bufnr].undolevels ~= 0
end

function Undo:isEmpty()
    local res = api.nvim_buf_call(self.bufnr, function()
        return api.nvim_exec('undolist', true)
    end)
    return not res:match('^number')
end

function Undo:loadUndo()
    return api.nvim_buf_call(self.bufnr, function()
        return pcall(cmd, 'sil rundo ' .. fn.fnameescape(self.undoPath))
    end)
end

function Undo:loadFileAndUndo(winid)
    local view
    if winid then
        view = api.nvim_win_call(winid, fn.winsaveview)
    end

    local ei = vim.o.eventignore
    vim.o.eventignore = 'all'
    pcall(function()
        local modified = vim.bo[self.bufnr].modified
        local lines = api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
        api.nvim_buf_call(self.bufnr, function()
            cmd(([[
                keepalt sil %dread %s
                keepj sil 1,%ddelete_
            ]]):format(#lines, fn.fnameescape(self.fallbackPath), #lines))
        end)
        self:loadUndo()
        api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)
        vim.bo[self.bufnr].modified = modified

        if winid then
            api.nvim_win_call(winid, function()
                fn.winrestview(view)
            end)
        end
    end)
    vim.o.eventignore = ei
end

function Undo:loadFallBack()
    if not uv.fs_stat(self.fallbackPath) then
        return
    end
    local winids = {}
    for _, winid in ipairs(api.nvim_list_wins()) do
        if self.bufnr == api.nvim_win_get_buf(winid) then
            table.insert(winids, winid)
        end
    end
    if #winids == 0 then
        self:loadFileAndUndo()
    elseif #winids > 1 then
        for _, winid in ipairs(winids) do
            self:loadFileAndUndo(winid)
        end
    else
        self:loadFileAndUndo(winids[1])
    end
end

function Undo:shouldTransfer()
    return self.attached and self.isDirty
end

function Undo:transfer()
    return async.run(function()
        if not self:shouldTransfer() then
            return
        end
        local stat = awaitFs(2, uv.fs_stat, self.undoPath)
        if stat then
            local tempPath = self.fallbackPath .. '.__'
            awaitFs(4, uv.fs_copyfile, self.name, tempPath)
            pcall(awaitFs, 3, uv.fs_rename, tempPath, self.fallbackPath)
        end
        self.isDirty = false
    end)
end

function Undo:check()
    if not self.attached or self.undoPath == '' then
        return
    end
    if self:isEmpty() then
        self:loadFallBack()
    end
end

return Undo
