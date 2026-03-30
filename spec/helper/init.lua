local uv = vim.uv
local async = require('async')

local M = {}

function M.setTimeout(callback, ms)
    local timer = uv.new_timer()
    timer:start(ms, 0, function()
        timer:close()
        callback()
    end)
    return timer
end

function M.delay(ms)
    return async.run(function()
        async.sleep(ms)
    end)
end

return M
