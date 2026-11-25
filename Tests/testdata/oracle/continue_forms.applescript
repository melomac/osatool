on describe()
    continue describe()
end describe

on pair(a, b)
    set x to continue pair(a, b)
    return "got " & x
end pair

on quit
    display dialog "bye"
    continue quit
end quit

on label(a)
    return "<" & (continue label(a)) & ">"
end label
