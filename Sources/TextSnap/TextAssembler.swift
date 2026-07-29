import Foundation
import Vision

/// Turns Vision's unordered observations into text that reads the way the screen looked.
///
/// Vision returns fragments in no guaranteed order, so we rebuild reading order from
/// the bounding boxes: group fragments into visual lines, order lines top to bottom,
/// then decide where paragraphs break from the vertical gaps.
enum TextAssembler {

    private struct Fragment {
        let text: String
        let box: CGRect          // normalized, origin bottom-left
        var charWidth: CGFloat { text.isEmpty ? box.width : box.width / CGFloat(text.count) }
    }

    private struct Line {
        var fragments: [Fragment]
        var minY: CGFloat { fragments.map(\.box.minY).min() ?? 0 }
        var maxY: CGFloat { fragments.map(\.box.maxY).max() ?? 0 }
        var minX: CGFloat { fragments.map(\.box.minX).min() ?? 0 }
        var height: CGFloat { maxY - minY }
        var midY: CGFloat { (maxY + minY) / 2 }
        var charWidth: CGFloat {
            let widths = fragments.map(\.charWidth).filter { $0 > 0 }
            guard !widths.isEmpty else { return 0.01 }
            return widths.reduce(0, +) / CGFloat(widths.count)
        }
    }

    static func assemble(_ observations: [VNRecognizedTextObservation],
                         keepLineBreaks: Bool,
                         preserveIndentation: Bool) -> String {

        let fragments: [Fragment] = observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string
            guard !text.isEmpty else { return nil }
            return Fragment(text: text, box: observation.boundingBox)
        }
        guard !fragments.isEmpty else { return "" }

        let lines = groupIntoLines(fragments)
        guard !lines.isEmpty else { return "" }

        let paragraphs = groupIntoParagraphs(lines)
        let leftEdge = lines.map(\.minX).min() ?? 0

        let rendered = paragraphs.map { paragraph in
            render(paragraph,
                   keepLineBreaks: keepLineBreaks,
                   preserveIndentation: preserveIndentation && keepLineBreaks,
                   leftEdge: leftEdge)
        }

        return rendered
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: Grouping

    private static func groupIntoLines(_ fragments: [Fragment]) -> [Line] {
        // Top of the screen has the highest normalized y.
        let sorted = fragments.sorted { $0.box.midY > $1.box.midY }
        var lines: [Line] = []

        for fragment in sorted {
            if var last = lines.last {
                let tolerance = 0.5 * max(fragment.box.height, last.height)
                if abs(fragment.box.midY - last.midY) < tolerance {
                    last.fragments.append(fragment)
                    lines[lines.count - 1] = last
                    continue
                }
            }
            lines.append(Line(fragments: [fragment]))
        }

        // Left to right within each line.
        return lines.map { line in
            Line(fragments: line.fragments.sorted { $0.box.minX < $1.box.minX })
        }
    }

    private static func groupIntoParagraphs(_ lines: [Line]) -> [[Line]] {
        var paragraphs: [[Line]] = [[lines[0]]]

        for index in 1..<lines.count {
            let previous = lines[index - 1]
            let current = lines[index]
            let gap = previous.minY - current.maxY
            let reference = max((previous.height + current.height) / 2, 0.0001)

            // A gap wider than half a line height reads as a new paragraph.
            if gap > reference * 0.55 {
                paragraphs.append([current])
            } else {
                paragraphs[paragraphs.count - 1].append(current)
            }
        }
        return paragraphs
    }

    // MARK: Rendering

    private static func render(_ lines: [Line],
                               keepLineBreaks: Bool,
                               preserveIndentation: Bool,
                               leftEdge: CGFloat) -> String {
        let texts = lines.map { line -> String in
            var out = ""
            for (index, fragment) in line.fragments.enumerated() {
                guard index > 0 else { out = fragment.text; continue }
                let previous = line.fragments[index - 1]
                let gap = fragment.box.minX - previous.box.maxX
                // A gap several characters wide is column spacing, not a word space.
                if keepLineBreaks, gap > line.charWidth * 3 {
                    out += "\t"
                } else {
                    out += " "
                }
                out += fragment.text
            }
            if preserveIndentation, line.charWidth > 0 {
                let indent = Int(((line.minX - leftEdge) / line.charWidth).rounded())
                if indent > 0 { out = String(repeating: " ", count: min(indent, 40)) + out }
            }
            return out
        }

        guard !keepLineBreaks else { return texts.joined(separator: "\n") }

        // Paragraph mode: reflow into one run, healing hyphenated wraps.
        var out = ""
        for text in texts {
            if out.isEmpty { out = text; continue }
            if let last = out.last, last == "-" || last == "\u{00AD}" {
                let stem = out.dropLast()
                // Only heal when a word was genuinely split, not on a dash between words.
                if let tail = stem.last, tail.isLetter {
                    out = String(stem) + text
                    continue
                }
            }
            out += " " + text
        }
        return out
    }
}
