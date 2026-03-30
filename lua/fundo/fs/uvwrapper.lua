local uv = vim.loop
local async = require('async')

---@class FundoFsUvWrapper
local UVWrapper = {}

local function pack(...)
    return {n = select('#', ...), ...}
end

local function unpack_len(t, i)
    return unpack(t, i or 1, t.n)
end

local function makeTask(fn)
    return async.run(fn)
end

local function assign(name, argc)
    UVWrapper[name] = function(...)
        local args = pack(...)
        return makeTask(function()
            local res = pack(async.await(argc, uv['fs_' .. name], unpack_len(args)))
            local err = res[1]
            if err then
                error(err, 0)
            end
            return unpack_len(res, 2)
        end)
    end
end

assign('close', 2)
assign('open', 4)
assign('read', 4)
assign('unlink', 2)
assign('write', 4)
assign('mkdir', 3)
assign('mkdtemp', 2)
assign('mkstemp', 2)
assign('rmdir', 2)
assign('stat', 2)
assign('fstat', 2)
assign('lstat', 2)
assign('rename', 3)
assign('fsync', 2)
assign('fdatasync', 2)
assign('ftruncate', 3)
assign('sendfile', 5)
assign('access', 3)
assign('chmod', 3)
assign('fchmod', 3)
assign('utime', 4)
assign('futime', 4)
assign('lutime', 4)
assign('link', 3)
assign('symlink', 4)
assign('readlink', 2)
assign('realpath', 2)
assign('chown', 4)
assign('fchown', 4)
assign('lchown', 4)
assign('copyfile', 4)
assign('readdir', 2)
assign('closedir', 2)
assign('statfs', 2)

function UVWrapper.opendir(path, entries)
    return makeTask(function()
        local err, dir = async.await(2, uv.fs_opendir, path, nil, entries)
        if err then
            error(err, 0)
        end
        return dir
    end)
end

for name, fn in pairs(UVWrapper) do
    if type(fn) == 'function' then
        UVWrapper[name .. 'Sync'] = uv['fs_' .. name]
    end
end

return UVWrapper
