#!/usr/bin/osascript

on run
    tell application "Xcode"
        -- Create a new project
        activate
        delay 1
        
        -- Use menu to create new project
        tell application "System Events"
            tell process "Xcode"
                -- File > New > Project
                click menu item "Project..." of menu "New" of menu item "New" of menu "File" of menu bar 1
                delay 2
                
                -- Select iOS App template
                click button "iOS" of window 1
                delay 0.5
                click row 1 of table 1 of scroll area 1 of window 1 -- App template
                delay 0.5
                click button "Next" of window 1
                delay 1
                
                -- Fill in project details
                set value of text field 1 of window 1 to "FSPRani3" -- Product Name
                delay 0.5
                set value of text field 2 of window 1 to "com.fsp" -- Organization Identifier
                delay 0.5
                
                -- Select SwiftUI interface
                click pop up button 1 of window 1
                delay 0.5
                click menu item "SwiftUI" of menu 1 of pop up button 1 of window 1
                delay 0.5
                
                -- Click Next
                click button "Next" of window 1
                delay 1
                
                -- Save location
                keystroke "g" using {command down, shift down}
                delay 0.5
                keystroke "/Volumes/FSP/FSPRani3"
                delay 0.5
                keystroke return
                delay 1
                click button "Create" of window 1
            end tell
        end tell
    end tell
end run