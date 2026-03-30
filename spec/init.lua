local pwd = os.getenv('PWD')
local deps = table.concat({
    pwd .. '/lua/?.lua',
    pwd .. '/lua/?/init.lua',
    pwd .. '/../async.nvim/lua/?.lua',
    pwd .. '/../async.nvim/lua/?/init.lua'
}, ';')
package.path = deps .. ';' .. package.path

require('busted.compatibility').exit = function(code)
    vim.schedule(function()
        vim.cmd(('cq %d'):format(code))
    end)
end
_G.assert = require('luassert')
_G.arg = vim.fn.argv()
_G.print = function(...)
    local argv = {...}
    for i = 1, #argv do
        argv[i] = tostring(argv[i])
    end
    table.insert(argv, '\n')
    io.write(unpack(argv))
end

require('busted.runner')({standalone = false, output = 'spec.helper.outputHandler'})
vim.cmd('cq 0')
