# WolvenKit for macOS

Native macOS workspace application targeting macOS 14 and Apple Silicon.

## Build and run

Requirements: macOS 14 or later and Xcode 15 or later.

```sh
cd Mac/WolvenKitMac
swift run
```

The workspace module creates and opens `.cpmodproj` project files, writes the project metadata as XML, stores recent project paths in the user's preferences, creates the standard project directory structure, and lists files in the selected project. Project files remain at the user-selected location.

## Source layout

```text
Sources/WolvenKitMac/
├── App/                 Application lifecycle and menu commands
├── Models/              Project and file data types
├── Services/            Project persistence and file-system access
├── ViewModels/          Observable workspace state and actions
└── Views/               Project workspace and creation flow
```
