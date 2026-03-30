local _done
local _result
local _err
local defaultTimeout = 1000
local busted = require('busted')
busted.subscribe({'suite', 'start'}, function()
    vim.env.TMPDIR = vim.env.TMPDIR or '/tmp/fundo'
end)
busted.subscribe({'test', 'start'}, function()
    _done = false
    _result = nil
    _err = nil
end)
busted.subscribe({'suite', 'end'}, function()
end)

local function getDone()
    return _done
end

---@return boolean
function _G.done()
    _done = true
    return _done
end

---@param err? any
---@param res? any
---@return boolean
function _G.done_with(err, res)
    _err = err
    _result = res
    _done = true
    return _done
end

---@param ms? number
---@return boolean, string
function _G.wait(ms)
    if getDone() then
        return _err == nil, _err or _result
    end
    local interval = 20
    ms = ms or defaultTimeout
    local ret = vim.wait(ms, getDone, interval, false)
    return ret and _err == nil, _err or _result
end
