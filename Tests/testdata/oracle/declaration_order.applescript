script base
end script

property parent : base
property p : 1

on f()
    return p
end f

script s
    on a()
    end a

    property q : 2

    script t
    end script

    on b()
    end b
end script

property final : 3

tell current application to beep
log f()
