script helper
    on greet(visitor)
        return "hello " & visitor
    end greet
end script

script main
    script inner
        on run
            return helper's greet(visitor)
        end run
    end script

    on run
        run inner
    end run
end script

on run argv
    set visitor to item 1 of argv
    run main
end run
