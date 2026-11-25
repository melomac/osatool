script base
    property label : "base"

    on describe()
        return label
    end describe
end script

script derived
    property parent : base

    on describe()
        return "derived from " & (continue describe())
    end describe
end script

on run
    return derived's describe()
end run
