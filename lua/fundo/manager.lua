local fn = vim.fn
local uv = vim.loop
local api = vim.api

local event = require('fundo.lib.event')
local disposable = require('fundo.lib.disposable')
local undo = require('fundo.model.undo')
local async = require('async')
local config = require('fundo.config')
local log = require('fundo.lib.log')
local path = require('fundo.fs.path')

---@class FundoManager
---@field initialized boolean
---@field undos table<number, FundoUndo>
---@field lastScannedtime number
---@field mutex vim.async.Semaphore
---@field disposables FundoDisposable[]
local Manager = {}

local function awaitFs(argc, op, ...)
    local err, result = async.await(argc, op, ...)
    if err then
        error(err, 0)
    end
    return result
end

local function isTask(value)
    return type(value) == 'table' and type(value.wait) == 'function'
end

local function all(tasks)
    return async.run(function()
        local results = {}
        for key, value in pairs(tasks) do
            if isTask(value) then
                results[key] = async.await(value)
            else
                results[key] = value
            end
        end
        return results
    end)
end

local function allSettled(tasks)
    return async.run(function()
        local results = {}
        for key, value in pairs(tasks) do
            if isTask(value) and type(value.detach) == 'function' then
                value:detach()
            end
            local ok, res = pcall(function()
                if isTask(value) then
                    return async.await(value)
                end
                return value
            end)
            if ok then
                results[key] = {status = 'fulfilled', value = res}
            else
                results[key] = {status = 'rejected', reason = res}
            end
        end
        return results
    end)
end

function Manager:attach(bufnr)
    if not self.undos[bufnr] then
        local u = undo:new(bufnr, self.archivesDir)
        if u:attach() then
            self.undos[bufnr] = u
        end
    end
    return self.undos[bufnr]
end

function Manager:listFileStats(dir, bufferSize)
    return async.run(function()
        local stream = awaitFs(2, uv.fs_opendir, dir, nil, bufferSize or 32)
        local tasks = {}
        local ok, res = pcall(function()
            while true do
                local entries = awaitFs(2, uv.fs_readdir, stream)
                if not entries then
                    break
                end
                for _, entry in ipairs(entries) do
                    if entry.type == 'file' then
                        local name = entry.name
                        tasks[name] = async.run(function()
                            return awaitFs(2, uv.fs_stat, path.join(dir, name))
                        end)
                    end
                end
            end
        end)
        awaitFs(2, uv.fs_closedir, stream)
        assert(ok, res)
        return async.await(all(tasks))
    end)
end

function Manager:scanArchivesDir()
    return async.run(function()
        log.debug('scanning archives dir')
        local statTbl = async.await(self:listFileStats(self.archivesDir, 1024))
        local stats = {}
        for name, stat in pairs(statTbl) do
            table.insert(stats, {name = name, mtime = stat.mtime.sec, size = stat.size})
        end
        table.sort(stats, function(a, b)
            return a.mtime > b.mtime
        end)
        local size = 0
        local limit = self.limitArchivesSize * 1024 * 1024
        local tasks = {}
        for _, stat in ipairs(stats) do
            if size > limit then
                local p = path.join(self.archivesDir, stat.name)
                log.debug(p, 'will be removed.')
                table.insert(tasks, async.run(function()
                    awaitFs(2, uv.fs_unlink, p)
                end))
            end
            size = size + stat.size
        end
        return async.await(all(tasks))
    end)
end

function Manager:syncAll(block)
    return async.run(function()
        return self.mutex:with(function()
        return async.run(function()
            local tasks = {}
            for bufnr, u in pairs(self.undos) do
                if u:shouldTransfer() then
                    local task = u:transfer()
                    task:detach()
                    tasks[bufnr] = task
                end
            end
            if vim.tbl_isempty(tasks) then
                return
            end
            local completed = false
            local p = allSettled(tasks)
            p:wait(function()
                completed = true
            end)
            local now = uv.hrtime()
            if block then
                vim.wait(1000, function()
                    return completed
                end, 30, false)
                log.debug(('has elaspsed %dms'):format((uv.hrtime() - now) / 1e6))
            end
            local results = async.await(p)
            log.debug('results:', results)
            -- 60 * 60 * 1e9 ns = 1 hour
            if not block and now - self.lastScannedtime > 60 * 60 * 1e9 then
                self.lastScannedtime = now
                async.await(self:scanArchivesDir())
            end
            completed = true
        end)
        end)
    end)
end

function Manager:initialize()
    if self.initialized then
        return self
    end
    self.initialized = true
    self.archivesDir = path.normalize(config.archives_dir)
    self.limitArchivesSize = config.limit_archives_size
    -- convert 0o755 to decimal base
    uv.fs_mkdir(self.archivesDir, 493)
    self.undos = {}
    self.lastScannedtime = uv.hrtime()
    self.mutex = async.semaphore(1)
    self.disposables = {}
    table.insert(self.disposables, disposable:create(function()
        for _, b in pairs(self.undos) do
            b:dispose()
        end
        self.initialized = false
        self.undos = {}
        self.lastScannedtime = 0
    end))
    event:on('BufReadPost', function(bufnr)
        local u = self:attach(bufnr)
        if u then
            u:check()
        end
    end, self.disposables)
    event:on('BufWritePost', function(bufnr)
        local u = self.undos[bufnr]
        if u then
            u:reset(true)
        end
    end, self.disposables)
    event:on('BufWipeout', function(bufnr)
        local u = self.undos[bufnr]
        if u then
            u:dispose()
            self.undos[bufnr] = nil
        end
    end, self.disposables)
    event:on('CmdlineEnter', function(char)
        if char ~= ':' then
            return
        end
        vim.schedule(function()
            if api.nvim_get_mode().mode == 'c' and fn.getcmdtype() == ':' then
                self:syncAll():raise_on_error()
            end
        end)
    end, self.disposables)
    event:on('VimLeave', function() self:syncAll(true):raise_on_error() end, self.disposables)
    event:on('VimSuspend', function() self:syncAll(true):raise_on_error() end, self.disposables)
    event:on('TermEnter', function() self:syncAll():raise_on_error() end, self.disposables)
    event:on('FocusLost', function() self:syncAll():raise_on_error() end, self.disposables)
    return self
end

---
---@param bufnr number
---@return FundoUndo
function Manager:get(bufnr)
    return self.undos[bufnr]
end

function Manager:dispose()
    disposable.disposeAll(self.disposables)
    self.disposables = {}
end

return Manager
