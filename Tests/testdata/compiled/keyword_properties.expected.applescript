property size : 3
property id : "top"
property name : "script"
property version : "1.0"
property color : {1, 2, 3}

script outer
    property bounds : {0, 0, 1, 1}
    property name : "outer"
    property label : "x"

    script inner
        on show()
            return {size, bounds, label, id}
        end show
    end script

    on reset()
        set size to 0
        set bounds to {0, 0, 0, 0}
        return inner's show()
    end reset
end script

set size to size + 1
return {size, id, name, version, color, bounds of outer, outer's reset()}
