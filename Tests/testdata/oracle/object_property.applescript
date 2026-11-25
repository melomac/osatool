property object : 1

script holder
    property object : 2
    property other : 3
end script

on run
    return object + (object of holder) + (other of holder)
end run
