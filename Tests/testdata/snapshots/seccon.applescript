use framework "Foundation"
use scripting additions
property california : {9, 1}
property t1 : {{9, 1}, {9, 1}}
property t2 : {{{9, 1}, {9, 1}}, {{9, 1}, {9, 1}}}
property t3 : {{{{9, 1}, {9, 1}}, {{9, 1}, {9, 1}}}, {{{9, 1}, {9, 1}}, {{9, 1}, {9, 1}}}}
property t4 : {{{{{9, 1}, {9, 1}}, {{9, 1}, {9, 1}}}, {{{9, 1}, {9, 1}}, {{9, 1}, {9, 1}}}}, {{{{9, 1}, {9, 1}}, {{9, 1}, {9, 1}}}, {{{9, 1}, {9, 1}}, {{9, 1}, {9, 1}}}}}
property nevada : {a:9, b:7}
property r1 : {x:{a:9, b:7}, y:{a:9, b:7}}
property r2 : {u:{x:{a:9, b:7}, y:{a:9, b:7}}, v:{x:{a:9, b:7}, y:{a:9, b:7}}}
property r3 : {j:{u:{x:{a:9, b:7}, y:{a:9, b:7}}, v:{x:{a:9, b:7}, y:{a:9, b:7}}}, k:{u:{x:{a:9, b:7}, y:{a:9, b:7}}, v:{x:{a:9, b:7}, y:{a:9, b:7}}}}
property texas : {5, 4, 3, 2, 1}
property florida2 : {foo:42, bar:99}

on run
    set oregon to text returned of (display dialog "Enter the flag" default answer "" buttons {"OK"} default button 1)
    considering numeric strings
        with timeout of 10 seconds
            set codex to {}
            copy codex to claude
            set FLAG to {california, california}
            set harrison to {nevada, nevada}
            if my Iidabashi(oregon) then
                display dialog "Correct!" buttons {"🎉"} default button 1
            else
                display dialog "Nope, keep trying." buttons {"Try again"} default button 1 with icon caution
            end if
        end timeout
    end considering

end run

on Iidabashi(candidate)
    set AMfnlJw9H0x to my Jimbocho(candidate)
    set virginia to my trimNSString(AMfnlJw9H0x)
    set southdakota to {83, 69, 67, 67, 79, 78, 123}
    set northdakota to 125
    set florida1 to 13
    set idaho to 6843
    set kansas1 to 6856
    set minnesota to {55, 169, 93}
    set iowa to 157
    set missouri to 24
    set nebraska1 to {{114, 131, 127, 125, 120, 130, 116, 133, 120, 129, 135, 117, 134, 129, 75, 68}}
    set montana to 95
    set arkansas to {U1F41D:1987, U1F99C:64104, U1F11D:5411, U1F41C:56473, len:16, U1F41B:19734}
    set ohio to {U1F41D:62601, U1F99C:65475, U1F11D:65339, len:6}
    set mississippi to my Roppongi(southdakota)
    set louisiana to my Otemachi(northdakota)
    set georgia to my Jimbocho(mississippi)
    set florida to my Jimbocho(louisiana)
    set utah to virginia's |length|() as integer
    if utah ≠ missouri then
        return false
    end if
    if (virginia's hasPrefix:georgia) ≠ true then
        return false
    end if
    if (virginia's hasSuffix:florida) ≠ true then
        return false
    end if
    set alabama to length of mississippi
    set NewYork to length of louisiana
    set indiana to current application's NSMakeRange(alabama, utah - alabama - NewYork)
    set michigan to virginia's substringWithRange:indiana
    set innerPayloadText to michigan as text
    set washington to my Shimbashi({innerPayloadText}, florida1, idaho, kansas1)
    if washington ≠ nebraska1 then
        return false
    end if
    if my Ginza(innerPayloadText) ≠ montana then
        return false
    end if
    set westvirginia to my Kanda(michigan, minnesota, iowa, idaho)
    set tennessee to item 2 of westvirginia
    if U1F41D of tennessee ≠ U1F41D of arkansas then
        return false
    end if
    if U1F99C of tennessee ≠ U1F99C of arkansas then
        return false
    end if
    if U1F11D of tennessee ≠ U1F11D of arkansas then
        return false
    end if
    if U1F41C of tennessee ≠ U1F41C of arkansas then
        return false
    end if
    if len of tennessee ≠ len of arkansas then
        return false
    end if
    if U1F41B of tennessee ≠ U1F41B of arkansas then
        return false
    end if
    set illinois to my Sugamo(michigan, minnesota, iowa)
    if U1F41D of illinois ≠ U1F41D of ohio then
        return false
    end if
    if U1F99C of illinois ≠ U1F99C of ohio then
        return false
    end if
    if U1F11D of illinois ≠ U1F11D of ohio then
        return false
    end if
    if len of illinois ≠ len of ohio then
        return false
    end if
    return true

end Iidabashi

on Roppongi(newyorkcity)
    set U1F41A to ""
    repeat with cid in newyorkcity
        set U1F41A to U1F41A & character id cid of it
    end repeat
    return U1F41A
end Roppongi

on Otemachi(cid)
    return character id cid of it
end Otemachi

on Kanda(nsPayload, NewJersey, U1F9E7, westchester)
    set U1F9C0 to nsPayload as text
    set U1F9A4 to nsPayload's |length|() as integer
    set U1F9A5 to {item 1 of NewJersey, item 2 of NewJersey, item 3 of NewJersey}
    set U1F984 to {U1F41D:0, U1F99C:0, U1F11D:westchester, U1F41C:0, U1F41B:westchester, len:U1F9A4}
    set AGENTS to {}
    repeat with idx from 1 to U1F9A4
        set code to ASCII number character idx of U1F9C0
        set U1F434 to code - 128
        set U1F427 to (idx * U1F9E7 + (item 1 of U1F9A5)) mod 257
        set Pennsylvania to U1F434 * U1F427 + (item 2 of U1F9A5)
        set alaska to (item 3 of U1F9A5) - idx
        if alaska = 0 then
            set alaska to -1
        end if
        set q to Pennsylvania div alaska
        set U1FAB8 to U1F427
        if U1FAB8 = 0 then
            set U1FAB8 to 1
        end if
        set r to Pennsylvania mod U1FAB8
        set U1F99C of U1F984 to ((U1F99C of U1F984) + q + r) mod 65536
        set U1F41D of U1F984 to (U1F41D of U1F984) + Pennsylvania
        set U1F11D of U1F984 to ((U1F11D of U1F984) + q + r) mod 65536
        set U1F41C of U1F984 to (U1F41C of U1F984) + (item 1 of U1F9A5) - (item 3 of U1F9A5)
        set item 1 of U1F9A5 to (item 1 of U1F9A5) + r
        set item 2 of U1F9A5 to (item 2 of U1F9A5) - q
        set item 3 of U1F9A5 to -(item 3 of U1F9A5) + code mod 5
        set U1FABC to (q + r + U1F9E7) mod 65536
        set U1F41B of U1F984 to ((U1F41B of U1F984) + U1FABC * (idx + 3)) mod 65536
        set end of AGENTS to U1FABC
    end repeat
    set U1F9D1 to {U1F41D:((U1F41D of U1F984) mod 65536 + 65536) mod 65536, U1F99C:((U1F99C of U1F984) mod 65536 + 65536) mod 65536, U1F11D:((U1F11D of U1F984) mod 65536 + 65536) mod 65536, U1F41C:((U1F41C of U1F984) mod 65536 + 65536) mod 65536, len:U1F9A4 mod 65536, U1F41B:((U1F41B of U1F984) mod 65536 + 65536) mod 65536}
    return {AGENTS, U1F9D1}
end Kanda

on Sugamo(nsPayload, NewJersey, U1F9E7)
    set U1F9C0 to nsPayload as text
    set guardLen to length of U1F9C0
    if guardLen > 6 then
        set guardLen to 6
    end if
    set U1F9A5 to {item 1 of NewJersey, item 2 of NewJersey, item 3 of NewJersey}
    set U1F984 to {U1F41D:0, U1F99C:0, U1F11D:0, len:guardLen}
    repeat with idx from 1 to guardLen
        set code to ASCII number character idx of U1F9C0
        set Pennsylvania to (code - 128) * (item 1 of U1F9A5) + (item 2 of U1F9A5)
        set alaska to (item 3 of U1F9A5) - idx
        if alaska = 0 then
            set alaska to -1
        end if
        set q to Pennsylvania div alaska
        set U1FAB8 to (item 1 of U1F9A5) - code mod 9
        if U1FAB8 = 0 then
            set U1FAB8 to 1
        end if
        set r to Pennsylvania mod U1FAB8
        set U1F99C of U1F984 to ((U1F99C of U1F984) + q + r) mod 65536
        set U1F41D of U1F984 to ((U1F41D of U1F984) + Pennsylvania) mod 65536
        set U1F11D of U1F984 to ((U1F11D of U1F984) + q * r) mod 65536
        set item 1 of U1F9A5 to (item 1 of U1F9A5) + r
        set item 2 of U1F9A5 to (item 2 of U1F9A5) - q
        set item 3 of U1F9A5 to -(item 3 of U1F9A5) + code mod 7
    end repeat
    set U1F9D1 to {U1F41D:((U1F41D of U1F984) mod 65536 + 65536) mod 65536, U1F99C:((U1F99C of U1F984) mod 65536 + 65536) mod 65536, U1F11D:((U1F11D of U1F984) mod 65536 + 65536) mod 65536, len:guardLen}
    return U1F9D1
end Sugamo

on Jimbocho(t)
    return current application's NSString's stringWithString:t
end Jimbocho

on trimNSString(ns)
    set ws to current application's NSCharacterSet's whitespaceAndNewlineCharacterSet()
    return ns's stringByTrimmingCharactersInSet:ws
end trimNSString

on splitNSString(ns, delim)
    if delim = "" then
        return {ns as text}
    end if
    set parts to ns's componentsSeparatedByString:delim
    return parts as list
end splitNSString

on Shimbashi(washingtondc, colorado, idaho, kansas)
    set AGENTS to {}
    set hawaii to (kansas - idaho) mod 256
    repeat with txt in washingtondc
        set U1F40E to 0
        set U1F9AD to {}
        repeat with ch in txt as text
            set U1F40E to U1F40E + 1
            set code to ASCII number ch
            set U1F30A to hawaii * (U1F40E mod 3 + 1) mod 11
            set end of U1F9AD to code + colorado + U1F30A
        end repeat
        set end of AGENTS to U1F9AD
    end repeat
    return AGENTS
end Shimbashi

on Ginza(t)
    set U1F420 to 0
    repeat with i from 1 to length of t
        set U1F420 to U1F420 + (ASCII number character i of t)
    end repeat
    return U1F420 mod 256
end Ginza

on stripWhitespace(t)
    if t = "" then
        return ""
    end if
    set cleaned to t
    set ws to {space, tab, return, linefeed}
    repeat while cleaned ≠ "" and ws contains character 1 of cleaned
        set cleaned to text 2 thru -1 of cleaned
    end repeat
    repeat while cleaned ≠ "" and ws contains character -1 of cleaned
        set cleaned to text 1 thru -2 of cleaned
    end repeat
    return cleaned
end stripWhitespace

on split(t, delim)
    if delim = "" then
        return {t}
    end if
    set oldDelims to text item delimiters of AppleScript
    set text item delimiters of AppleScript to delim
    set itemsList to every text item of t
    set text item delimiters of AppleScript to oldDelims
    return itemsList
end split
