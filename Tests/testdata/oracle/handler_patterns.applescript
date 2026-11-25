script one
    on run argv
        return argv
    end run
end script

script two
    on run {a, b}
        return a & b
    end run
end script

on rec({x:a, y:b}, c)
    return a & b & c
end rec

on pat(a, {b, c})
    return a & b & c
end pat

on spread of {a, b} by y
    return a & b & y
end spread

on open {first_item, second_item}
    return first_item
end open

on run {input, parameters}
    rec({x:1, y:2}, 3)
    pat(1, {2, 3})
    return spread of {1, 2} by 3
end run
