script settings
    property label : "base"
    property limit : 3
end script

script finderChild
    property parent : application "Finder"

    on answer()
        return 1
    end answer
end script

script child
    property parent : settings

    on describe()
        return label & limit
    end describe
end script

on run
    return child's describe()
end run
