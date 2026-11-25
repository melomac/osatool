global shared

on reader()
    global shared, other
    set other to shared
    set mine to other
    return mine
end reader

script worker
    on run
        global shared
        set x to shared
        return x
    end run
end script

local secret
set secret to 1
set shared to secret
repeat with i from 1 to 2
    log i
end repeat
try
    error "x"
on error msg number n
    log msg
end try
reader()
