local path = require('fundo.fs.path')

---@class FundoConfig
local defaults = {
    archives_dir = vim.fn.stdpath('cache') .. path.sep .. 'fundo',
    limit_archives_size = 512
}

---@type FundoConfig
local Config = vim.deepcopy(defaults)

local function apply(opts)
    local config = vim.tbl_deep_extend('keep', opts or {}, defaults)
    vim.validate('archives_dir', config.archives_dir, 'string')
    vim.validate('limit_archives_size', config.limit_archives_size, 'number')
    Config.archives_dir = vim.fn.expand(config.archives_dir)
    Config.limit_archives_size = config.limit_archives_size
end

---@param opts? FundoConfig
function Config.setup(opts)
    apply(opts)
end

apply()

return Config
