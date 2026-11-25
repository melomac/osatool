tell application "System Events"
    set matchingProcesses to every process whose not (frontmost = true) and name ≠ ""
    tell item 1 of matchingProcesses
        return properties
    end tell
end tell
