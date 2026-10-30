# WolvenKit for macOS architecture

## Product target

- macOS 14 and later
- Apple Silicon (arm64)
- Swift 5.10 language compatibility, with strict concurrency enabled as modules are converted
- SwiftUI views, observable MVVM state, asynchronous services, and dependency injection
- Project metadata remains interoperable with the `.cpmodproj` XML format

## Module boundaries

```text
Mac/WolvenKitMac/
├── Package.swift
└── Sources/WolvenKitMac/
    ├── App/                 Scene lifecycle, menu commands, dependency graph
    ├── Models/              Projects, game resources, archive entries, editor documents
    ├── Services/            Persistence, archive access, codecs, import/export, settings
    ├── ViewModels/          Observable state and user actions for each workspace
    └── Views/               SwiftUI shell, project tools, editors, inspectors, dialogs
```

The application target owns composition and navigation. View models coordinate user intent and publish display state. Services own file access, persistence, parsing, compression, and background work. Models contain validated values and format-specific types. Views do not perform direct file-system or archive operations.

## Dependency flow

```text
SwiftUI Views → ViewModels → Service protocols → Service implementations
                         ↘ Models ↗
App composition root → concrete service registrations
```

Services are passed into view models through initializers. Long-running indexing, decoding, and conversion work runs away from the main actor. UI-facing observable state is isolated to the main actor. File access uses `URL`, `FileManager`, security-scoped access when selected by the user, and application support locations for preferences and indexes.

## Feature modules

| Module | Responsibilities | Status |
|---|---|---|
| Project workspace | Create/open project, preserve metadata, recents, project file listing | Implemented in the first slice |
| Asset intake | Copy selected files into project source folders with collision-safe names | Implemented in the first slice |
| Asset catalog | Search, filter, sort, and inspect indexed project files | Implemented in the second slice |
| Archive access and build | Validate headers and indexes, list entries, extract raw-main entries, create archives from hash-named files and preserve internal resource buffers | Index read, raw extraction and uncompressed archive build implemented; Kraken decoding remains unavailable |
| Resource formats | Parse headers, tables, imports, exports, buffers, embedded entries and variable records | Structural parsing, scalar primitive decoding, and checksum-preserving same-length byte edits implemented; complex typed values and full serialization remain |
| Editors | Edit text and resource bytes, preview audio, convert images | Text, image, audio preview and raw resource editors implemented; typed resource, graph, timeline, localization and tweak editors remain |
| Conversion pipeline | Import/export formats, image/audio conversion, batch operations and progress | PNG/JPEG/TIFF image conversion implemented; broader media and game-format conversion remains |
| Scripting | Isolated script execution, editor integration, diagnostics and permissions | JavaScript project inspection and reviewable text edits implemented; broader app APIs and execution controls remain |
| Preferences | Game locations, author defaults, editor behavior and persistent user settings | Not started |

## Delivery sequence

1. Establish the project workspace and its persistence contract.
2. Add asset intake and a searchable project asset catalog.
3. Add archive path/hash dictionaries and Oodle-compatible arm64 decompression and compression.
4. Port resource parsing and serialization as independent services on the archive index contract.
5. Build editors on the validated model and service APIs.
6. Add conversion, scripting, settings, diagnostics, packaging, and end-to-end compatibility checks.

Each module must ship with complete source, explicit failure handling, and a successful macOS arm64 build before dependent modules are treated as complete.
