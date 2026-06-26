This program is a macOS command‑line tool that renames video files whose names start with D and end with .MP4 by prefixing them with their creation date, which it reads from the video metadata using ffprobe

swiftc -O main.swift -o RenameMP4ByCreationDate -framework Cocoa

./RenameMP4ByCreationDate
