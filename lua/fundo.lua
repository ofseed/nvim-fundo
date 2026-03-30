local M = {}
local api = vim.api
local fs = vim.fs

local manager = require('fundo.manager')

---@class FundoConfig
local defaults = {
  archives_dir = fs.joinpath(vim.fn.stdpath('cache'), 'fundo'),
  limit_archives_size = 512,
}

---@type FundoConfig
local config = {
  archives_dir = vim.fn.expand(defaults.archives_dir),
  limit_archives_size = defaults.limit_archives_size,
}

local enabled
local groupId

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
        if api.nvim_get_mode().mode == 'c' and vim.fn.getcmdtype() == ':' then
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
    archives_dir = vim.fn.expand(cfg.archives_dir),
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
