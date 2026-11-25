script main
    on run
        set greeting to "hello " & visitor
        return greeting
    end run
end script

on run argv
    try
        set visitor to item 1 of argv
        run main
    end try
end run
