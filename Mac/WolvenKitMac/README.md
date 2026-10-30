# WolvenKit for macOS

Native macOS workspace application targeting macOS 14 and Apple Silicon.

## Build and run

Requirements: macOS 14 or later and Xcode 15 or later.

```sh
cd Mac/WolvenKitMac
swift run
```

The workspace module creates and opens `.cpmodproj` project files, writes the project metadata as XML, stores recent project paths in the user's preferences, creates the standard project directory structure, and lists files in the selected project. Project files remain at the user-selected location. Assets can be copied into `source/raw` and searched, filtered, sorted, and inspected in the asset catalog.

The archive catalog validates the archive header and index tables, displays entry hashes, segment ranges, sizes, timestamps, and SHA-1 values, and exports entries whose segments are stored without compression. Compressed entry decoding is not part of this build.

For standalone resource files, the catalog reads the fixed header fields and first string-table entry to show the resource class, format/build versions, and chunk count. It does not yet parse or rewrite resource properties.

## Source layout

```text
Sources/WolvenKitMac/
├── App/                 Application lifecycle and menu commands
├── Models/              Project and file data types
├── Services/            Project persistence and file-system access
├── ViewModels/          Observable workspace state and actions
└── Views/               Project workspace and creation flow
```
