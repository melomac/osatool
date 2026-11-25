on describe given flag:f, size:n
    return {f, n}
end describe

on polish to x
    return x
end polish

on findNumbers of numberList above minLimit given rounding:roundBoolean
    return {numberList, minLimit, roundBoolean}
end findNumbers

on slide over a under b thru c
    return {a, b, c}
end slide

on flags given alpha:a, beta:b, gamma:c, delta:d
    return {a, b, c, d}
end flags

on mix(a, b)
    return a & b
end mix

describe with flag given size:2
describe without flag given size:4
polish to 5
findNumbers of {1, 2} above 1 without rounding
slide over 1 under 2 thru 3
flags with alpha and gamma without beta given delta:1
flags with alpha, beta and gamma given delta:"d"
flags given alpha:(1 > 0), beta:2, gamma:3, delta:(4 + 1)
set r to (polish to 6) & mix(1, 2)
tell me
    polish to 7
end tell
tell application "Finder"
    flags of me given alpha:1, beta:2, gamma:3, delta:4
end tell
return r
