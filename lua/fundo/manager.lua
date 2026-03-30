local uv = vim.loop

local undo = require('fundo.model.undo')
local async = require('async')
local log = require('fundo.lib.log')
local path = require('fundo.fs.path')

---@class FundoManager
---@field initialized boolean
---@field undos table<number, FundoUndo>
---@field lastScannedtime number
---@field mutex vim.async.Semaphore
local Manager = {}

local function awaitFs(argc, op, ...)
    local err, result = async.await(argc, op, ...)
    if err then
        error(err, 0)
    end
    return result
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

function Manager:detach(bufnr)
    local u = self.undos[bufnr]
    if u then
        u:dispose()
        self.undos[bufnr] = nil
    end
end

function Manager:listFileStats(dir, bufferSize)
    return async.run(function()
        local stream = awaitFs(2, uv.fs_opendir, dir, nil, bufferSize or 32)
        local stats = {}
        local ok, res = pcall(function()
            while true do
                local entries = awaitFs(2, uv.fs_readdir, stream)
                if not entries then
                    break
                end
                for _, entry in ipairs(entries) do
                    if entry.type == 'file' then
                        local name = entry.name
                        stats[name] = awaitFs(2, uv.fs_stat, path.join(dir, name))
                    end
                end
            end
        end)
        awaitFs(2, uv.fs_closedir, stream)
        assert(ok, res)
        return stats
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
        for _, stat in ipairs(stats) do
            if size > limit then
                local p = path.join(self.archivesDir, stat.name)
                log.debug(p, 'will be removed.')
                awaitFs(2, uv.fs_unlink, p)
            end
            size = size + stat.size
        end
    end)
end

function Manager:syncAll(block)
    return async.run(function()
        return self.mutex:with(function()
            return async.run(function()
                local p = async.run(function()
                    local tasks = {}
                    for _, u in pairs(self.undos) do
                        if u:shouldTransfer() then
                            table.insert(tasks, u:transfer())
                        end
                    end
                    if vim.tbl_isempty(tasks) then
                        return
                    end
                    return async.await_all(tasks)
                end)
                local completed = false
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

---@param cfg FundoConfig
function Manager:initialize(cfg)
    if self.initialized then
        return self
    end
    self.initialized = true
    self.archivesDir = path.normalize(cfg.archives_dir)
    self.limitArchivesSize = cfg.limit_archives_size
    -- convert 0o755 to decimal base
    uv.fs_mkdir(self.archivesDir, 493)
    self.undos = {}
    self.lastScannedtime = uv.hrtime()
    self.mutex = async.semaphore(1)
    return self
end

---
---@param bufnr number
---@return FundoUndo
function Manager:get(bufnr)
    return self.undos[bufnr]
end

function Manager:dispose()
    for _, b in pairs(self.undos) do
        b:dispose()
    end
    self.initialized = false
    self.undos = {}
    self.lastScannedtime = 0
end

return Manager
