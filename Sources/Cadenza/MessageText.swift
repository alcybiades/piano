import SwiftUI

/// Lightweight block rendering for tutor prose and chord comparison tables.
/// SwiftUI Text handles inline Markdown; a Grid handles Markdown table blocks.
struct MessageText: View {
    let text: String
    private enum Block {
        case prose(String)
        case heading(String)
        case code(String)
        case table([[String]])
    }
    private var blocks: [Block] {
        let lines = text.components(separatedBy: "\n")
        var result: [Block] = [], prose: [String] = [], i = 0
        func flush() { if !prose.isEmpty { result.append(.prose(prose.joined(separator: "\n"))); prose = [] } }
        func cells(_ line: String) -> [String] { line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("```") {
                flush(); i += 1; var code: [String] = []
                while i < lines.count, !lines[i].hasPrefix("```") { code.append(lines[i]); i += 1 }
                result.append(.code(code.joined(separator: "\n"))); i += 1
            } else if line.hasPrefix("#") {
                flush(); result.append(.heading(line.drop(while: { $0 == "#" || $0 == " " }).description)); i += 1
            } else if line.contains("|"), i + 1 < lines.count, lines[i + 1].contains("---"), cells(lines[i + 1]).allSatisfy({ $0.allSatisfy { "-: ".contains($0) } }) {
                flush(); var rows = [cells(line)]; i += 2
                while i < lines.count, lines[i].contains("|"), !lines[i].isEmpty { rows.append(cells(lines[i])); i += 1 }
                result.append(.table(rows))
            } else { prose.append(line); i += 1 }
        }
        flush(); return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let content): Text(.init(content)).font(.system(size: 13)).lineSpacing(5)
                case .heading(let content): Text(.init(content)).font(.system(size: 15, weight: .semibold)).padding(.top, 5)
                case .code(let content): Text(content).font(.system(size: 11, design: .monospaced)).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Studio.raised, in: RoundedRectangle(cornerRadius: 6))
                case .table(let rows):
                    Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Text(.init(cell)).font(.system(size: 11, weight: rowIndex == 0 ? .semibold : .regular)).foregroundStyle(rowIndex == 0 ? Studio.mint : .white.opacity(0.85)) }
                            }
                            if rowIndex == 0 { Rectangle().fill(Studio.line).frame(height: 1).gridCellColumns(rows[0].count) }
                        }
                    }.padding(14).background(Studio.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }
}
