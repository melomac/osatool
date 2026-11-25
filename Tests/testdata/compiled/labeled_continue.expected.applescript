script base
    on polish to x
        return x
    end polish

    on describe given flag:f, size:n
        return {f, n}
    end describe

    on spread of x by y
        return x & y
    end spread
end script

script derived
    property parent : base

    on polish to x
        return (continue polish to (x + 1)) & "!"
    end polish

    on describe given flag:f, size:n
        continue describe given flag:f, size:(n + 1)
    end describe

    on spread of x by y
        continue spread of (x & "!") by y
    end spread
end script

tell derived
    polish to 5
end tell
tell derived
    describe with flag given size:1
end tell
tell derived
    spread of "a" by "b"
end tell
