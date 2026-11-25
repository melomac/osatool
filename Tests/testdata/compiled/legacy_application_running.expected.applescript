tell application "System Settings"
    set current pane to pane id "com.apple.preference.general"
end tell
return application "System Events" is running
