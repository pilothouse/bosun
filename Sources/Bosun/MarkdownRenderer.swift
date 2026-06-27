import AppKit
import Markdown

/// One top-level block of a rendered Markdown body. Everything that isn't a *fenced* code block —
/// paragraphs, lists, headings, quotes, inline code — folds into `.text` (a themed
/// `NSAttributedString`); a top-level fenced code block becomes `.code(raw)` so `DetailView` can
/// render it as a padded, copyable box rather than inline tinted text. Code blocks nested inside a
/// list/quote stay inside `.text`, rendered by `visitCodeBlock`.
enum MarkdownBlock {
    case text(NSAttributedString)
    case code(String)
}

/// Splits a GitHub-flavored Markdown body into an ordered stack of blocks (see `MarkdownBlock`),
/// pulling top-level fenced code blocks out as their own segments. Issue/PR/comment bodies arrive as
/// raw Markdown; this walks the parsed tree and emits headings, emphasis, inline code, lists
/// (including `- [ ]` task items), blockquotes, links, and strikethrough, all tinted from the app
/// `Theme`. Consecutive non-code blocks render together so their inter-paragraph spacing stays intact,
/// then have the dangling trailing newline(s) trimmed so a segment's height isn't padded by an empty
/// final line.
///
/// `swift-markdown` parses with the cmark-gfm extensions (strikethrough + task lists) always
/// registered, so no `ParseOptions` flag is needed for those. Unsupported constructs (raw HTML,
/// tables, images) degrade to their text content.
func renderMarkdownBlocks(_ text: String, theme: Theme, baseFont: NSFont) -> [MarkdownBlock] {
    var renderer = MarkdownRenderer(theme: theme, baseFont: baseFont)
    var blocks: [MarkdownBlock] = []
    let pending = NSMutableAttributedString()
    func flushText() {
        while pending.length > 0, (pending.string as NSString).hasSuffix("\n") {
            pending.deleteCharacters(in: NSRange(location: pending.length - 1, length: 1))
        }
        if pending.length > 0 {
            blocks.append(.text(NSAttributedString(attributedString: pending)))
            pending.setAttributedString(NSAttributedString())
        }
    }
    for child in Document(parsing: text).children {
        if let codeBlock = child as? CodeBlock {
            flushText()
            var code = codeBlock.code
            if code.hasSuffix("\n") { code.removeLast() }   // cmark keeps a trailing newline
            blocks.append(.code(code))
        } else {
            pending.append(renderer.visit(child))
        }
    }
    flushText()
    return blocks
}

/// A monospaced font that reads at the same *visual* size as `baseFont` for code. SF Mono and SF Pro
/// share cap/x-height at equal point size, but mono reads optically heavier (thicker strokes) and
/// wider (fixed advance), so we trim it to `codeFontRatio` of the body to match the perceived size
/// (tuned by eye). `baseFont.pointSize` already has `uiScale` baked in (it's `sys(…)`), so we derive
/// the size from it directly — NOT via `mono()`, which would re-apply `uiScale` and double-scale at zoom.
func monoCodeFont(matching baseFont: NSFont) -> NSFont {
    NSFont.monospacedSystemFont(ofSize: baseFont.pointSize * codeFontRatio, weight: .regular)
}
private let codeFontRatio: CGFloat = 0.88   // ≈ body − 1.6pt at the 13.5pt default

/// Opens clicked Markdown links in the user's browser. Stateless, so `DetailView` keeps one shared
/// instance for every (rebuilt-each-layout) text view. Mirrors `DeviceFlowSheet`'s `NSWorkspace.open`.
final class MarkdownLinkDelegate: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        if let url { NSWorkspace.shared.open(url); return true }
        return false
    }
}

/// A `MarkupVisitor` that folds the Markdown tree into an `NSAttributedString`. Inline visitors
/// return styled runs; block visitors wrap their children with a paragraph style and a single
/// trailing newline (inter-block spacing comes from `paragraphSpacing`, never blank lines).
private struct MarkdownRenderer: MarkupVisitor {
    typealias Result = NSAttributedString

    let theme: Theme
    let baseFont: NSFont
    /// Nesting level of the list currently being rendered (0 = not in a list, 1 = outermost).
    var listDepth = 0

    private var baseAttrs: [NSAttributedString.Key: Any] { [.font: baseFont, .foregroundColor: theme.txt2] }
    private var newline: NSAttributedString { NSAttributedString(string: "\n", attributes: [.font: baseFont]) }
    private var tab: NSAttributedString { NSAttributedString(string: "\t", attributes: [.font: baseFont]) }

    /// Monospaced font for inline code (and code blocks nested in lists/quotes), matched to the body's
    /// visual size. Top-level fenced blocks render outside this visitor — see `renderMarkdownBlocks`.
    private var codeFont: NSFont { monoCodeFont(matching: baseFont) }

    // MARK: Tree walk

    mutating func defaultVisit(_ markup: Markup) -> NSAttributedString {
        visitChildren(markup)
    }

    private mutating func visitChildren(_ markup: Markup) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        for child in markup.children { out.append(visit(child)) }
        return out
    }

    // MARK: Inline

    mutating func visitText(_ text: Markdown.Text) -> NSAttributedString {
        NSAttributedString(string: text.string, attributes: baseAttrs)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> NSAttributedString {
        // CommonMark soft break → a space; the text reflows to the container width.
        NSAttributedString(string: " ", attributes: baseAttrs)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: baseAttrs)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> NSAttributedString {
        let m = visitChildren(emphasis)
        restyleFonts(m) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
        return m
    }

    mutating func visitStrong(_ strong: Strong) -> NSAttributedString {
        let m = visitChildren(strong)
        restyleFonts(m) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
        return m
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> NSAttributedString {
        let m = visitChildren(strikethrough)
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
        m.addAttribute(.strikethroughColor, value: theme.txt3, range: full)
        return m
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> NSAttributedString {
        NSAttributedString(string: inlineCode.code, attributes: [
            .font: codeFont,
            .foregroundColor: theme.txt,
            .backgroundColor: theme.accentbg,
        ])
    }

    mutating func visitLink(_ link: Link) -> NSAttributedString {
        let m = visitChildren(link)
        let full = NSRange(location: 0, length: m.length)
        if let dest = link.destination, let url = URL(string: dest) {
            m.addAttribute(.link, value: url, range: full)
        }
        m.addAttribute(.foregroundColor, value: theme.accent, range: full)
        m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: full)
        return m
    }

    // MARK: Blocks

    mutating func visitParagraph(_ paragraph: Paragraph) -> NSAttributedString {
        let s = NSMutableParagraphStyle()
        s.paragraphSpacing = baseFont.pointSize * 0.55
        s.lineSpacing = 2
        return terminate(visitChildren(paragraph), with: s)
    }

    mutating func visitHeading(_ heading: Heading) -> NSAttributedString {
        let size: CGFloat, weight: NSFont.Weight, color: NSColor
        switch heading.level {
        case 1: (size, weight, color) = (baseFont.pointSize + 9, .bold, theme.txt)
        case 2: (size, weight, color) = (baseFont.pointSize + 5, .bold, theme.txt)
        case 3: (size, weight, color) = (baseFont.pointSize + 2, .semibold, theme.txt)
        case 4: (size, weight, color) = (baseFont.pointSize + 0.5, .semibold, theme.txt)
        case 5: (size, weight, color) = (baseFont.pointSize, .semibold, theme.txt3)
        default: (size, weight, color) = (baseFont.pointSize, .semibold, theme.txt4)
        }
        let s = NSMutableParagraphStyle()
        s.paragraphSpacingBefore = baseFont.pointSize * 0.7
        s.paragraphSpacing = baseFont.pointSize * 0.3
        let m = terminate(visitChildren(heading), with: s)
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.font, value: sys(size, weight), range: full)
        m.addAttribute(.foregroundColor, value: color, range: full)
        return m
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> NSAttributedString {
        var code = codeBlock.code
        if code.hasSuffix("\n") { code.removeLast() }   // cmark keeps a trailing newline
        let s = NSMutableParagraphStyle()
        s.firstLineHeadIndent = 10
        s.headIndent = 10
        s.paragraphSpacingBefore = baseFont.pointSize * 0.2
        s.paragraphSpacing = baseFont.pointSize * 0.5
        s.lineSpacing = 2
        let m = NSMutableAttributedString(string: code, attributes: [
            .font: codeFont,
            .foregroundColor: theme.txt,
            .backgroundColor: theme.accentbg2,
        ])
        return terminate(m, with: s, applyToTerminator: true)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> NSAttributedString {
        // Inner paragraphs already carry their own style + trailing newline; override indent and
        // mute the text. (A true left rule needs custom drawing — out of scope.)
        let m = visitChildren(blockQuote)
        let s = NSMutableParagraphStyle()
        s.firstLineHeadIndent = 14
        s.headIndent = 14
        s.paragraphSpacing = baseFont.pointSize * 0.5
        s.lineSpacing = 2
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.paragraphStyle, value: s, range: full)
        m.addAttribute(.foregroundColor, value: theme.txt3, range: full)
        return m
    }

    mutating func visitUnorderedList(_ list: UnorderedList) -> NSAttributedString {
        listDepth += 1
        defer { listDepth -= 1 }
        let out = NSMutableAttributedString()
        for item in list.listItems {
            let marker: NSAttributedString
            switch item.checkbox {
            case .checked: marker = markerRun("☑", color: theme.accent)
            case .unchecked: marker = markerRun("☐", color: theme.txt4)
            case nil: marker = markerRun("•", color: theme.txt3)
            }
            out.append(renderItem(item, marker: marker))
        }
        return out
    }

    mutating func visitOrderedList(_ list: OrderedList) -> NSAttributedString {
        listDepth += 1
        defer { listDepth -= 1 }
        let out = NSMutableAttributedString()
        var n = list.startIndex
        for item in list.listItems {
            out.append(renderItem(item, marker: markerRun("\(n).", color: theme.txt3)))
            n += 1
        }
        return out
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> NSAttributedString {
        let s = NSMutableParagraphStyle()
        s.paragraphSpacingBefore = baseFont.pointSize * 0.3
        s.paragraphSpacing = baseFont.pointSize * 0.3
        let rule = NSMutableAttributedString(string: String(repeating: "─", count: 24), attributes: [
            .font: sys(baseFont.pointSize - 2),
            .foregroundColor: theme.line2,
        ])
        return terminate(rule, with: s, applyToTerminator: true)
    }

    // MARK: Helpers

    /// Renders one list item: a marker line (marker + tab + inline content) plus any nested lists.
    private mutating func renderItem(_ item: ListItem, marker: NSAttributedString) -> NSAttributedString {
        let style = listItemStyle(depth: listDepth)
        let out = NSMutableAttributedString()
        var leadEmitted = false
        for child in item.children {
            if child is UnorderedList || child is OrderedList {
                out.append(visit(child))   // recurse — deeper indent via incremented listDepth
                continue
            }
            let content: NSAttributedString = (child as? Paragraph).map { visitChildren($0) } ?? visit(child)
            let line = NSMutableAttributedString()
            line.append(leadEmitted ? tab : marker)   // first line gets the marker, later ones align under it
            line.append(tab)
            line.append(content)
            line.append(newline)
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
            leadEmitted = true
        }
        if !leadEmitted {   // an empty item (no paragraph) — still show its marker
            let line = NSMutableAttributedString()
            line.append(marker); line.append(newline)
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
        }
        return out
    }

    private func listItemStyle(depth: Int) -> NSParagraphStyle {
        let markerX = CGFloat(max(depth - 1, 0)) * 22 + 2
        let textX = CGFloat(max(depth, 1)) * 22
        let s = NSMutableParagraphStyle()
        s.firstLineHeadIndent = markerX
        s.headIndent = textX
        s.tabStops = [NSTextTab(textAlignment: .left, location: textX)]
        s.paragraphSpacing = 3
        s.lineSpacing = 2
        return s
    }

    private func markerRun(_ glyph: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: glyph, attributes: [.font: baseFont, .foregroundColor: color])
    }

    /// Appends a trailing newline and applies `style` to the paragraph. With `applyToTerminator`
    /// the newline keeps the block's own attributes (used for code / rules so the gap renders).
    private func terminate(_ content: NSMutableAttributedString, with style: NSParagraphStyle,
                           applyToTerminator: Bool = false) -> NSMutableAttributedString {
        let bodyLen = content.length
        content.append(newline)
        content.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: content.length))
        if applyToTerminator, bodyLen > 0 {
            // copy font/colors from the last body char onto the terminator so its line height matches
            let attrs = content.attributes(at: bodyLen - 1, effectiveRange: nil)
            content.addAttributes(attrs.filter { $0.key != .paragraphStyle }, range: NSRange(location: bodyLen, length: 1))
        }
        return content
    }

    /// Re-maps the font on every run via `transform`, preserving run boundaries so nested
    /// emphasis/strong (and mono inline code) compose instead of clobbering one another.
    private func restyleFonts(_ s: NSMutableAttributedString, _ transform: (NSFont) -> NSFont) {
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            let font = (value as? NSFont) ?? baseFont
            s.addAttribute(.font, value: transform(font), range: range)
        }
    }
}
