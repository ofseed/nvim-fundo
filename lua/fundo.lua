local M = {}
local api = vim.api
local fn = vim.fn
local cmd = vim.cmd
local fs = vim.fs
local uv = vim.uv

local async = require('async')

---@class FundoConfig
local defaults = {
  archives_dir = fs.joinpath(fn.stdpath('cache'), 'fundo'),
  limit_archives_size = 512,
}

---@type FundoConfig
local config = {
  archives_dir = fn.expand(defaults.archives_dir),
  limit_archives_size = defaults.limit_archives_size,
}

local enabled
local groupId

-- Bridge libuv callback APIs into async.nvim and surface fs errors as Lua errors.
local function awaitFs(argc, op, ...)
  local err, result = async.await(argc, op, ...)
  if err then
    error(err, 0)
  end
  return result
end

---@class FundoUndo
---@field name? string Absolute path of the file currently tracked by this buffer.
---@field undoPath? string Path of Neovim's undofile for the tracked file.
---@field fallbackPath? string Archive file used by fundo to restore undo state.
---@field isDirty? boolean Whether the fallback archive should be refreshed on the next sync.
---@field dir string Absolute path of fundo's archive directory.
---@field bufnr number Buffer handle associated with this state object.
---@field attached boolean Whether fundo is currently managing this buffer.
local Undo = {}

---@return FundoUndo
function Undo:new(bufnr, dir)
  local o = setmetatable({}, self)
  self.__index = self
  o.bufnr = bufnr
  o.dir = dir
  return o
end

---Attach fundo state to a buffer if it uses an undofile.
function Undo:attach()
  local bt = vim.bo[self.bufnr].bt
  local name = api.nvim_buf_get_name(self.bufnr)
  if fs.normalize(fs.dirname(name)) == self.dir then
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

---Refresh tracked file paths after a buffer name change or write.
---@param dirty? boolean
---@param bufName? string
function Undo:reset(dirty, bufName)
  if not self.attached then
    return
  end
  local name = bufName or api.nvim_buf_get_name(self.bufnr)
  if name ~= self.name then
    self.undoPath = fn.undofile(name)
    self.fallbackPath = fs.joinpath(self.dir, fs.basename(self.undoPath))
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

---Load the undo file into the target buffer.
function Undo:loadUndo()
  return api.nvim_buf_call(self.bufnr, function()
    return pcall(cmd, 'sil rundo ' .. fn.fnameescape(self.undoPath))
  end)
end

---Restore fallback file contents while preserving the current buffer text and view.
function Undo:loadFileAndUndo(winid)
  local view
  if winid then
    view = api.nvim_win_call(winid, fn.winsaveview)
  end

  -- Temporarily replace the buffer with the archived file so :rundo can rebuild
  -- the undo tree, then restore the user's current text and window view.
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

---Restore fallback contents for every visible window showing this buffer.
function Undo:loadFallBack()
  if not uv.fs_stat(self.fallbackPath) then
    return
  end
  -- Apply the rebuilt undo state in every window that is currently showing
  -- this buffer so each window keeps a consistent view/restoration point.
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

---Copy the current buffer file to the fallback archive when the undofile exists.
function Undo:transfer()
  return async.run(function()
    if not self:shouldTransfer() then
      return
    end
    local stat = awaitFs(2, uv.fs_stat, self.undoPath)
    if stat then
      -- Write to a temporary archive first so a partial copy never replaces
      -- the last good fallback file.
      local tempPath = self.fallbackPath .. '.__'
      awaitFs(4, uv.fs_copyfile, self.name, tempPath)
      pcall(awaitFs, 3, uv.fs_rename, tempPath, self.fallbackPath)
    end
    self.isDirty = false
  end)
end

---Recover fallback contents when the current undofile is empty.
function Undo:check()
  if not self.attached or self.undoPath == '' then
    return
  end
  if self:isEmpty() then
    self:loadFallBack()
  end
end

---@class FundoManager
---@field initialized boolean Whether fundo has already created runtime state.
---@field undos table<number, FundoUndo> Undo state indexed by buffer handle.
---@field lastScannedtime number Last archive scan time in nanoseconds.
---@field mutex vim.async.Semaphore Serializes sync work across editor events.
---@field archivesDir? string Normalized directory used to store fallback archives.
---@field limitArchivesSize? number Maximum archive size in MiB before pruning.
local manager = {}

---Attach fundo tracking to a buffer on first use.
---@param bufnr number
---@return FundoUndo?
function manager:attach(bufnr)
  if not self.undos[bufnr] then
    local u = Undo:new(bufnr, self.archivesDir)
    if u:attach() then
      self.undos[bufnr] = u
    end
  end
  return self.undos[bufnr]
end

---Stop tracking a buffer and drop its cached undo state.
---@param bufnr number
function manager:detach(bufnr)
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
function manager:listFileStats(dir, bufferSize)
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
function manager:scanArchivesDir()
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
        local path = fs.joinpath(self.archivesDir, stat.name)
        awaitFs(2, uv.fs_unlink, path)
      end
      size = size + stat.size
    end
  end)
end

---Sync every dirty buffer to its fallback archive.
---@param block? boolean
---@return vim.async.Task
function manager:syncAll(block)
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
        async.await(p)
        -- 60 * 60 * 1e9 ns = 1 hour
        if not block and now - self.lastScannedtime > 60 * 60 * 1e9 then
          self.lastScannedtime = now
          async.await(self:scanArchivesDir())
        end
      end)
    end)
  end)
end

---Initialize runtime state for the current configuration.
---@param cfg FundoConfig
---@return FundoManager
function manager:initialize(cfg)
  if self.initialized then
    return self
  end
  self.initialized = true
  self.archivesDir = fs.normalize(cfg.archives_dir)
  self.limitArchivesSize = cfg.limit_archives_size
  uv.fs_mkdir(self.archivesDir, 493)
  self.undos = {}
  self.lastScannedtime = uv.hrtime()
  self.mutex = async.semaphore(1)
  return self
end

---Get the tracked undo state for a buffer.
---@param bufnr number
---@return FundoUndo?
function manager:get(bufnr)
  return self.undos[bufnr]
end

---Dispose all tracked undo state and reset manager runtime fields.
function manager:dispose()
  for _, b in pairs(self.undos) do
    b:dispose()
  end
  self.initialized = false
  self.undos = {}
  self.lastScannedtime = 0
end

local function createEvents()
  groupId = api.nvim_create_augroup('Fundo', {})
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
      manager:detach(t.buf)
    end,
  })
  api.nvim_create_autocmd('CmdlineEnter', {
    group = groupId,
    pattern = ':',
    callback = function(t)
      if t.file ~= ':' then
        return
      end
      -- Re-check on the next loop tick so command-line mode/type is fully updated
      -- before deciding whether fundo should flush pending undo state.
      vim.schedule(function()
        if api.nvim_get_mode().mode == 'c' and fn.getcmdtype() == ':' then
          manager:syncAll():raise_on_error()
        end
      end)
    end,
  })
  api.nvim_create_autocmd({ 'VimLeave', 'VimSuspend' }, {
    group = groupId,
    callback = function()
      manager:syncAll(true):raise_on_error()
    end,
  })
  api.nvim_create_autocmd({ 'TermEnter', 'FocusLost' }, {
    group = groupId,
    callback = function()
      manager:syncAll():raise_on_error()
    end,
  })
end

function M.enable()
  if enabled then
    return false
  end
  createEvents()
  manager:initialize(config)
  enabled = true
  return true
end

function M.disable()
  if not enabled then
    return false
  end
  if groupId then
    pcall(api.nvim_del_augroup_by_id, groupId)
    groupId = nil
  end
  manager:dispose()
  enabled = false
  return true
end

---Setup configuration and enable fundo
---@param opts? FundoConfig
function M.setup(opts)
  local cfg = vim.tbl_deep_extend('keep', opts or {}, defaults)
  vim.validate('archives_dir', cfg.archives_dir, 'string')
  vim.validate('limit_archives_size', cfg.limit_archives_size, 'number')
  config = {
    archives_dir = fn.expand(cfg.archives_dir),
    limit_archives_size = cfg.limit_archives_size,
  }
  if enabled then
    -- Rebuild runtime state so an already enabled plugin starts using the new
    -- archive directory and size limit immediately.
    M.disable()
    M.enable()
  end
end

return M
