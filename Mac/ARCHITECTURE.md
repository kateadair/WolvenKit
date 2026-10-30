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
| Archive access | Enumerate archive records, resolve paths and hashes, read entry payloads | Not started |
| Resource formats | Parse and serialize resource types, validate fields, preserve unknown data | Not started |
| Editors | Structured resource editor, graph editor, timeline editor, localization and tweak tools | Not started |
| Conversion pipeline | Import/export formats, image/audio conversion, batch operations and progress | Not started |
| Scripting | Isolated script execution, editor integration, diagnostics and permissions | Not started |
| Preferences | Game locations, author defaults, editor behavior and persistent user settings | Not started |

## Delivery sequence

1. Establish the project workspace and its persistence contract.
2. Add asset intake and a searchable project asset catalog.
3. Define archive-entry and resource model contracts before implementing archive readers.
4. Port archive reading, path/hash lookup, compression, and resource serialization as independent services.
5. Build editors on the validated model and service APIs.
6. Add conversion, scripting, settings, diagnostics, packaging, and end-to-end compatibility checks.

Each module must ship with complete source, explicit failure handling, and a successful macOS arm64 build before dependent modules are treated as complete.
