local fs = vim.fs
local uv = vim.uv

local undo = require('fundo.undo')
local async = require('async')

---@class FundoManager
---@field initialized boolean Whether fundo has already created runtime state.
---@field undos table<number, FundoUndo> Undo state indexed by buffer handle.
---@field lastScannedtime number Last archive scan time in nanoseconds.
---@field mutex vim.async.Semaphore Serializes sync work across editor events.
---@field archivesDir? string Normalized directory used to store fallback archives.
---@field limitArchivesSize? number Maximum archive size in MiB before pruning.
local Manager = {}

-- Bridge libuv callback APIs into async.nvim and surface fs errors as Lua errors.
local function awaitFs(argc, op, ...)
  local err, result = async.await(argc, op, ...)
  if err then
    error(err, 0)
  end
  return result
end

---Attach fundo tracking to a buffer on first use.
---@param bufnr number
---@return FundoUndo?
function Manager:attach(bufnr)
  if not self.undos[bufnr] then
    local u = undo:new(bufnr, self.archivesDir)
    if u:attach() then
      self.undos[bufnr] = u
    end
  end
  return self.undos[bufnr]
end

---Stop tracking a buffer and drop its cached undo state.
---@param bufnr number
function Manager:detach(bufnr)
  local u = self.undos[bufnr]
  if u then
    u:dispose()
    self.undos[bufnr] = nil
  end
end

---Collect file stat information for every archive file in a directory.
---@param dir string
---@param bufferSize? number
---@return vim.async.Task<table<string, uv.fs_stat_t>>
function Manager:listFileStats(dir, bufferSize)
  return async.run(function()
    local stream = awaitFs(2, uv.fs_opendir, dir, nil, bufferSize or 32)
    local stats = {}
    -- Always close the directory handle before re-raising any traversal error.
    local ok, res = pcall(function()
      while true do
        local entries = awaitFs(2, uv.fs_readdir, stream)
        if not entries then
          break
        end
        for _, entry in ipairs(entries) do
          if entry.type == 'file' then
            local name = entry.name
            stats[name] = awaitFs(2, uv.fs_stat, fs.joinpath(dir, name))
          end
        end
      end
    end)
    awaitFs(2, uv.fs_closedir, stream)
    assert(ok, res)
    return stats
  end)
end

---Remove old archive files when the archive directory exceeds the configured size.
---@return vim.async.Task
function Manager:scanArchivesDir()
  return async.run(function()
    local statTbl = async.await(self:listFileStats(self.archivesDir, 1024))
    local stats = {}
    for name, stat in pairs(statTbl) do
      table.insert(stats, { name = name, mtime = stat.mtime.sec, size = stat.size })
    end
    table.sort(stats, function(a, b)
      return a.mtime > b.mtime
    end)
    local size = 0
    local limit = self.limitArchivesSize * 1024 * 1024
    -- Keep newer archives first and delete older ones once the size limit
    -- has already been exceeded by the files retained so far.
    for _, stat in ipairs(stats) do
      if size > limit then
        local p = fs.joinpath(self.archivesDir, stat.name)
        awaitFs(2, uv.fs_unlink, p)
      end
      size = size + stat.size
    end
  end)
end

---Sync every dirty buffer to its fallback archive.
---@param block? boolean
---@return vim.async.Task
function Manager:syncAll(block)
  return async.run(function()
    -- Editor events can overlap, so serialize sync work behind one semaphore.
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
          -- Preserve the original behavior: perform a bounded synchronous
          -- wait first, then still await the task to completion below.
          vim.wait(1000, function()
            return completed
          end, 30, false)
        end
        local results = async.await(p)
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

---Initialize runtime state for the current configuration.
---@param cfg FundoConfig
---@return FundoManager
function Manager:initialize(cfg)
  if self.initialized then
    return self
  end
  self.initialized = true
  self.archivesDir = fs.normalize(cfg.archives_dir)
  self.limitArchivesSize = cfg.limit_archives_size
  -- convert 0o755 to decimal base
  uv.fs_mkdir(self.archivesDir, 493)
  self.undos = {}
  self.lastScannedtime = uv.hrtime()
  self.mutex = async.semaphore(1)
  return self
end

---Get the tracked undo state for a buffer.
---@param bufnr number
---@return FundoUndo?
function Manager:get(bufnr)
  return self.undos[bufnr]
end

---Dispose all tracked undo state and reset manager runtime fields.
function Manager:dispose()
  for _, b in pairs(self.undos) do
    b:dispose()
  end
  self.initialized = false
  self.undos = {}
  self.lastScannedtime = 0
end

return Manager
