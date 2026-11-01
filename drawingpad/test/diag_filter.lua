local ext = "%.dwgz$|%.drawing$"
local function listed(fn)
    local lower = fn:lower()
    for p in ext:gmatch("[^|]+") do
        if lower:match(p) then return true end
    end
    return false
end
print("a.dwgz:", listed("a.DWGZ"))
print("b.drawing:", listed("b.drawing"))
print("c.png:", listed("c.png"))
print("d.dwgz.bak:", listed("d.dwgz.bak"))
