import SwiftUI
import AppKit

struct HexPayloadEditorView: View {
    let document: CR2WDocument
    let export: CR2WExportRecord
    let variable: CR2WVariableRecord?
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var scalarValue = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(variable.map { "\($0.propertyName) · \($0.typeName)" } ?? "Chunk \(export.index + 1) · \(export.className)")
                    .font(.title3.weight(.semibold))
                Text("\(editedData.count.formatted()) bytes · offset 0x\(String(editOffset, radix: 16).uppercased()) · same-length edits only")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if let variable, variable.scalarKind != nil {
                HStack(spacing: 10) {
                    TextField("Typed scalar value", text: $scalarValue)
                        .textFieldStyle(.roundedBorder)
                    Button("Save Typed Value", action: saveTypedValue)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving)
                }
                Text("This property's primitive value is decoded from its stored bytes. Saving keeps the original field length.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textEditorStyle(.plain)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Chunk bytes in hexadecimal")

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            HStack {
                Text("The save recalculates the chunk, export-table, and resource-header checksums.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Bytes", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 560)
        .task(id: "\(export.index)-\(variable?.index ?? -1)") {
            text = format(editedData)
            scalarValue = variable.flatMap { item in
                item.scalarKind?.decode(item.data)
            } ?? ""
            errorMessage = nil
        }
    }

    private func format(_ data: Data) -> String {
        var rows: [String] = []
        for start in stride(from: 0, to: data.count, by: 16) {
            let end = min(start + 16, data.count)
            let bytes = data[start..<end].map { String(format: "%02X", $0) }.joined(separator: " ")
            rows.append(bytes)
        }
        return rows.joined(separator: "\n")
    }

    private func parseHex() throws -> Data {
        let compact = text
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .filter { !$0.isWhitespace }
        guard compact.count.isMultiple(of: 2), compact.allSatisfy(\.isHexDigit) else {
            throw HexEditorError.invalidHex
        }
        var bytes = Data()
        var index = compact.startIndex
        while index < compact.endIndex {
            let next = compact.index(index, offsetBy: 2)
            guard let byte = UInt8(compact[index..<next], radix: 16) else { throw HexEditorError.invalidHex }
            bytes.append(byte)
            index = next
        }
        guard bytes.count == editedData.count else { throw CR2WDocumentError.changedPayloadSize }
        return bytes
    }

    private var editedData: Data {
        variable?.data ?? document.payload(for: export)
    }

    private var editOffset: UInt32 {
        variable?.dataOffset ?? export.dataOffset
    }

    private func save() {
        do {
            let payload = try parseHex()
            persist(payload)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveTypedValue() {
        guard let variable, let scalarKind = variable.scalarKind else { return }
        do {
            persist(try scalarKind.encode(scalarValue))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persist(_ payload: Data) {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                if let variable {
                    try await CR2WEditingService().replaceVariablePayload(payload, variable: variable, export: export, in: document)
                } else {
                    try await CR2WEditingService().replaceChunkPayload(payload, export: export, in: document)
                }
                onSaved()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private enum HexEditorError: LocalizedError {
    case invalidHex

    var errorDescription: String? {
        "Enter hexadecimal bytes only. Separate bytes with spaces or line breaks."
    }
}
