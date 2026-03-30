local async = require('async')
local uv = vim.loop
local uvw = require('fundo.fs.uvwrapper')

local FS = setmetatable({}, {__index = uvw})

for name in pairs(uvw) do
    if type(uvw[name]) == 'function' and not name:match('Sync$') then
        FS[name .. 'Sync'] = uv['fs_' .. name]
    end
end

function FS.copyFile(path, newPath)
    return async.run(function()
        local p = newPath .. '.__'
        async.await(uvw.copyfile(path, p))
        pcall(async.await, uvw.rename(p, newPath))
    end)
end

---@param path string
---@param bufferSize? number
---@param iterAction fun(entries: table): boolean?
---@return vim.async.Task
function FS.openDirStream(path, bufferSize, iterAction)

    return async.run(function()
        bufferSize = bufferSize or 32
        local dir = async.await(uvw.opendir(path, bufferSize))
        local entries
        local ok, res = pcall(function()
            repeat
                entries = async.await(uvw.readdir(dir))
                local stop = iterAction(entries)
                if type(stop) == 'table' and type(stop.wait) == 'function' then
                    stop = async.await(stop)
                end
                if stop then
                    break
                end
            until not entries
        end)
        async.await(uvw.closedir(dir))
        assert(ok, res)
    end)
end

return FS
