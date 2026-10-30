-- FRONTIER - LÖVE 2D configuration
function love.conf(t)
    t.identity = "frontier"
    t.version = "11.4"
    t.window.title = "Frontier"
    t.window.width = 1280
    t.window.height = 720
    t.window.resizable = true
    t.window.minwidth = 960
    t.window.minheight = 600
    t.window.vsync = 1
    t.window.msaa = 4
end
