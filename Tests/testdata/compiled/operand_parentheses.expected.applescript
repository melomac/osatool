on amount()
    return 1
end amount

on arithmetic(x, y, p)
    set a to {(p of x) + y, y - (item 1 of x), (items 1 thru 2 of x) * y, y / (every item of x), (p of x) ^ y}
    set b to {(x's amount()) + y, y - (my amount()), (my amount()) div y, y mod (x's amount())}
    set c to {amount() + y, y - amount(), amount() * y, y * (amount()), y / (amount()), y div (amount()), y mod (amount()), y ^ (amount()), amount() ^ y}
    set d to {(application "Finder") + y, (length of "abc") + 1, (item 1 of {1, 2}) * 2, -(p of x), y + (p of x) * 2}
    return {a, b, c, d}
end arithmetic

on others(x, y, p)
    set a to {p of x & y, y = item 1 of x, x's amount() & y, my amount() = y, y & amount(), name of x as text, not p of x, p of x and y}
    set b to {(every item of x whose p = 1) as text, (every item of x whose p = 1) & y, y = (every item of x whose p = 1)}
    set c to {y + (a reference to x), y & (a reference to x), {a reference to x, y}, contents of (a reference to x)}
    return {a, b, c}
end others

on inside(x, y)
    tell x
        return {(item 1) + y, (window id 7) - y, (item named "a") * y, name + y, every item & y, some item + y, (item 1) * y, items 1 thru 2 & y}
    end tell
end inside
