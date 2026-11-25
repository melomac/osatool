property first_property : 1
property second_property : 2

on listPatterns(x, y)
    set {a, b} to {x, y}
    set {c, {d, e}} to {x, {y, x}}
    set {{f, g}, h} to {{x, y}, x}
    set {i} to x
    set {j, k, l} to x
    set {x, y} to {y, x}
    return {a, b, c, d, e, f, g, h, i, j, k, l}
end listPatterns

on recordPatterns(x)
    set {name:a, id:b} to x
    set {width:c, height:d} to x
    set {name:e, bounds:{f, g}} to x
    set {{name:h}, i} to x
    return {a, b, c, d, e, f, g, h, i}
end recordPatterns

on copyPatterns(x, y)
    copy {x, y} to {a, b}
    copy x to {c, {d, e}}
    copy {name:x} to {name:f}
    copy x to g
    return {a, b, c, d, e, f, g}
end copyPatterns

on targetKinds(x, z)
    global shared
    set {first_property, second_property} to x
    set {shared, item 1 of z} to x
    set {a, name of z} to x
    set {oldDelimiters, text item delimiters of AppleScript} to {text item delimiters of AppleScript, ","}
    set parts to every text item of x
    set text item delimiters of AppleScript to oldDelimiters
    return {a, parts}
end targetKinds

on valueKinds(x)
    set {a, b} to amount()
    set {c, d} to items 1 thru 2 of x
    set {e, f} to x & {1}
    tell x
        set {g, h} to {name, 2}
    end tell
    repeat with n from 1 to 2
        set {i, j} to {n, n + 1}
    end repeat
    if a = b then
        set {k, l} to {1, 2}
    else
        set {k, l} to {3, 4}
    end if
    set m to a reference to x
    set o to a reference to item 1 of x
    return {a, b, c, d, e, f, g, h, i, j, k, l, m, o}
end valueKinds

on amount()
    return {1, 2}
end amount
