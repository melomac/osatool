on check(x)
    if x = 1 then
        return "one"
    else if x = 2 then
        return "two"
    else if x = 3 then
        return "three"
    else
        return "many"
    end if
end check

on forms(x, t)
    set a to items 2 thru 3 of x
    set b to -(item 1 of x) + -t
    set c to t as text & "!"
    set d to "<" & (t as text)
    set e to name of me
    set g to not (a = b) and not c
    set end of x to check(1)
    repeat with i from 1 to 3 by 2
        log i
    end repeat
    repeat with i from 1 to 3
        log i
    end repeat
    return {a, b, c, d, e, g, application "Finder" is running, application "Finder" is not running}
end forms

on run argv
    «event coregetd» 1
    display dialog "x"
    return forms(argv, 1)
end run
