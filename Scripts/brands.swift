// Converts the icon variants (`*-icon.svg`) of gilbarbara/logos (CC0,
// https://github.com/gilbarbara/logos) into one-colour brand marks for the
// icon picker, in the same text format as Lotion/Design/Hugeicons.txt.
//
// Logos are drawn in colours; a mark has one. Shapes are painted in order:
// a shape that stands out from the one under it (black on yellow, white on
// orange) is cut out of the mark, anything else adds to it, and white on
// nothing is left out. Each mark is then sized to look as big as a Hugeicon
// in the same 24-unit grid (see `mark`).
//
//   git clone --depth 1 https://github.com/gilbarbara/logos.git
//   swift Scripts/brands.swift logos Lotion/Design/Brands.txt
//
// Brands that don't come out recognisable go in `skipped` below.
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let repo = URL(fileURLWithPath: args[1])
let output = URL(fileURLWithPath: args[2])

/// Marks that lose what makes them recognisable in one colour.
let skipped: Set<String> = ["activeloop", "codium", "flutter", "kimi", "lateral", "lovable", "opencode", "vite", "viteplus"]

/// Marks whose shading reads better judged by a plain difference in
/// luminance than by contrast ratio.
let byDifference: Set<String> = ["angular", "sendgrid"]

// SVG path parsing, as in Scripts/hugeicons.swift.

func parsePath(_ d: String, into path: CGMutablePath) {
    var tokens: [String] = []
    var current = ""
    let chars = Array(d)
    var i = 0
    func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
    while i < chars.count {
        let c = chars[i]
        if c.isLetter && c != "e" && c != "E" { flush(); tokens.append(String(c)) }
        else if c == "," || c == " " || c == "\n" || c == "\t" { flush() }
        else if c == "-" && !current.isEmpty && !(current.last == "e" || current.last == "E") { flush(); current = "-" }
        else if c == "." && current.contains(".") && !(current.contains("e") || current.contains("E")) { flush(); current = "." }
        else { current.append(c) }
        i += 1
    }
    flush()

    var idx = 0
    var cmd: Character = "M"
    var p = CGPoint.zero, start = CGPoint.zero
    var lastControl: CGPoint? = nil, lastQuad: CGPoint? = nil
    func num() -> CGFloat { defer { idx += 1 }; return CGFloat(Double(tokens[idx])!) }
    func isNum() -> Bool { idx < tokens.count && !(tokens[idx].first!.isLetter) }
    func flag() -> Bool {
        // arc flags can be packed ("01") — take one character
        let t = tokens[idx]
        if t.count > 1 { tokens[idx] = String(t.dropFirst()); return t.first == "1" }
        idx += 1; return t == "1"
    }
    while idx < tokens.count {
        if !isNum() { cmd = Character(tokens[idx]); idx += 1 }
        let rel = cmd.isLowercase
        let base = rel ? p : .zero
        switch cmd.uppercased() {
        case "M":
            p = CGPoint(x: base.x + num(), y: base.y + num()); start = p; path.move(to: p)
            cmd = rel ? "l" : "L"; lastControl = nil; lastQuad = nil
        case "L":
            p = CGPoint(x: base.x + num(), y: base.y + num()); path.addLine(to: p); lastControl = nil; lastQuad = nil
        case "H":
            p = CGPoint(x: (rel ? p.x : 0) + num(), y: p.y); path.addLine(to: p); lastControl = nil; lastQuad = nil
        case "V":
            p = CGPoint(x: p.x, y: (rel ? p.y : 0) + num()); path.addLine(to: p); lastControl = nil; lastQuad = nil
        case "C":
            let c1 = CGPoint(x: base.x + num(), y: base.y + num())
            let c2 = CGPoint(x: base.x + num(), y: base.y + num())
            p = CGPoint(x: base.x + num(), y: base.y + num())
            path.addCurve(to: p, control1: c1, control2: c2); lastControl = c2; lastQuad = nil
        case "S":
            let c1 = lastControl.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
            let c2 = CGPoint(x: base.x + num(), y: base.y + num())
            p = CGPoint(x: base.x + num(), y: base.y + num())
            path.addCurve(to: p, control1: c1, control2: c2); lastControl = c2; lastQuad = nil
        case "Q":
            let c = CGPoint(x: base.x + num(), y: base.y + num())
            p = CGPoint(x: base.x + num(), y: base.y + num())
            path.addQuadCurve(to: p, control: c); lastQuad = c; lastControl = nil
        case "T":
            let c = lastQuad.map { CGPoint(x: 2 * p.x - $0.x, y: 2 * p.y - $0.y) } ?? p
            p = CGPoint(x: base.x + num(), y: base.y + num())
            path.addQuadCurve(to: p, control: c); lastQuad = c; lastControl = nil
        case "A":
            let rx = num(), ry = num(), rot = num()
            let large = flag(), sweep = flag()
            let end = CGPoint(x: base.x + num(), y: base.y + num())
            addArc(path, from: p, to: end, rx: rx, ry: ry, angle: rot, large: large, sweep: sweep)
            p = end; lastControl = nil; lastQuad = nil
        case "Z":
            path.closeSubpath(); p = start; lastControl = nil; lastQuad = nil
        default:
            fatalError("unsupported command \(cmd) in \(d)")
        }
    }
}

/// SVG endpoint arc → cubic Béziers (SVG spec F.6).
func addArc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
            angle: CGFloat, large: Bool, sweep: Bool) {
    var rx = abs(rxIn), ry = abs(ryIn)
    if rx == 0 || ry == 0 { path.addLine(to: p1); return }
    let phi = angle * .pi / 180, cosP = cos(phi), sinP = sin(phi)
    let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
    let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
    let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
    if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
    let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
    let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
    var coef = sqrt(max(0, num / den)); if large == sweep { coef = -coef }
    let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
    let cx = cosP * cxp - sinP * cyp + (p0.x + p1.x) / 2
    let cy = sinP * cxp + cosP * cyp + (p0.y + p1.y) / 2
    func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
        let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a
    }
    let theta1 = ang(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
    var delta = ang((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
    if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
    let segments = Int(ceil(abs(delta) / (.pi / 2)))
    let step = delta / CGFloat(segments)
    let k = 4 / 3 * tan(step / 4)
    var t = theta1
    func point(_ a: CGFloat) -> CGPoint {
        CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
    }
    func deriv(_ a: CGFloat) -> CGPoint {
        CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
    }
    for _ in 0..<segments {
        let a = point(t), b = point(t + step), da = deriv(t), db = deriv(t + step)
        path.addCurve(to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                      control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
        t += step
    }
}

func fmt(_ v: CGFloat, places: Int = 3) -> String {
    let s = String(format: "%.\(places)f", Double(v))
    var t = s
    while t.contains(".") && (t.hasSuffix("0") || t.hasSuffix(".")) { t.removeLast() }
    return t == "-0" ? "0" : t
}

func pathData(_ path: CGPath, places: Int = 3) -> String {
    var d = ""
    let f = { (v: CGFloat) in fmt(v, places: places) }
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}


// MARK: SVG documents

final class Node {
    let name: String
    let attributes: [String: String]
    var children: [Node] = []
    weak var parent: Node?
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }

    /// A presentation attribute, from `style` first, then the attribute itself.
    func property(_ key: String) -> String? {
        if let style = attributes["style"] {
            for declaration in style.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == key { return parts[1] }
            }
        }
        return attributes[key]
    }
}

final class TreeBuilder: NSObject, XMLParserDelegate {
    var root: Node?
    private var stack: [Node] = []
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        let node = Node(name: name, attributes: attributes)
        node.parent = stack.last
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }
}

func parse(_ url: URL) -> Node? {
    guard let parser = XMLParser(contentsOf: url) else { return nil }
    let builder = TreeBuilder()
    parser.delegate = builder
    return parser.parse() ? builder.root : nil
}

func numbers(_ text: String) -> [CGFloat] {
    var result: [CGFloat] = []
    let regex = try! NSRegularExpression(pattern: #"-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"#)
    for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        result.append(CGFloat(Double(text[Range(m.range, in: text)!])!))
    }
    return result
}

func length(_ text: String?) -> CGFloat? {
    text.flatMap { numbers($0).first }
}

func transform(_ text: String?) -> CGAffineTransform {
    guard let text else { return .identity }
    var result = CGAffineTransform.identity
    let regex = try! NSRegularExpression(pattern: #"(\w+)\s*\(([^)]*)\)"#)
    for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        let kind = String(text[Range(m.range(at: 1), in: text)!])
        let v = numbers(String(text[Range(m.range(at: 2), in: text)!]))
        var t = CGAffineTransform.identity
        switch kind {
        case "matrix" where v.count == 6: t = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        case "translate": t = CGAffineTransform(translationX: v.first ?? 0, y: v.count > 1 ? v[1] : 0)
        case "scale": t = CGAffineTransform(scaleX: v.first ?? 1, y: v.count > 1 ? v[1] : v.first ?? 1)
        case "rotate":
            let angle = (v.first ?? 0) * .pi / 180
            let cx = v.count > 2 ? v[1] : 0, cy = v.count > 2 ? v[2] : 0
            t = CGAffineTransform(translationX: cx, y: cy).rotated(by: angle).translatedBy(x: -cx, y: -cy)
        case "skewX": t = CGAffineTransform(a: 1, b: 0, c: tan((v.first ?? 0) * .pi / 180), d: 1, tx: 0, ty: 0)
        case "skewY": t = CGAffineTransform(a: 1, b: tan((v.first ?? 0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
        default: break
        }
        // Later transforms apply first: result = t × result, in CG's row-vector order.
        result = t.concatenating(result)
    }
    return result
}

// MARK: Colours

/// Relative luminance, 0 (black) to 1 (white).
func luminance(_ text: String, ids: [String: Node]) -> CGFloat? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    let value = trimmed.lowercased()
    if value == "none" || value == "transparent" { return nil }
    if value.hasPrefix("url(") {
        // Ids keep their case.
        let id = trimmed.dropFirst(4).drop { $0 == "#" || $0 == "'" || $0 == "\"" }.prefix { $0 != ")" && $0 != "'" && $0 != "\"" }
        return gradientLuminance(ids[String(id)], ids: ids)
    }
    let named: [String: String] = ["white": "#ffffff", "black": "#000000", "currentcolor": "#000000",
                                   "red": "#ff0000", "blue": "#0000ff", "green": "#008000", "yellow": "#ffff00",
                                   "orange": "#ffa500", "gray": "#808080", "grey": "#808080", "purple": "#800080"]
    var hex = named[value] ?? value
    if hex.hasPrefix("rgb") {
        let v = numbers(hex)
        guard v.count >= 3 else { return 0 }
        return relative(v[0] / 255, v[1] / 255, v[2] / 255)
    }
    guard hex.hasPrefix("#") else { return 0 }
    hex.removeFirst()
    if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard hex.count >= 6, let rgb = UInt32(hex.prefix(6), radix: 16) else { return 0 }
    return relative(CGFloat((rgb >> 16) & 0xFF) / 255, CGFloat((rgb >> 8) & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
}

func relative(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
    func linear(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
}

/// A gradient's colour, as the average of its stops.
func gradientLuminance(_ gradient: Node?, ids: [String: Node]) -> CGFloat? {
    guard var gradient else { return nil }
    var hops = 0
    while gradient.children.filter({ $0.name == "stop" }).isEmpty, hops < 5,
          let href = gradient.attributes["xlink:href"] ?? gradient.attributes["href"],
          let next = ids[String(href.drop { $0 == "#" })] {
        gradient = next
        hops += 1
    }
    let stops = gradient.children.filter { $0.name == "stop" }.compactMap { stop -> CGFloat? in
        guard let color = stop.property("stop-color") else { return 0 }
        return luminance(color, ids: ids)
    }
    return stops.isEmpty ? nil : stops.reduce(0, +) / CGFloat(stops.count)
}

// MARK: Painting

struct Style {
    var fill: String? = "#000000"
    var fillRule = "nonzero"
    var stroke: String?
    var strokeWidth: CGFloat = 1
    var opacity: CGFloat = 1

    func inherit(_ node: Node) -> Style {
        var style = self
        if let v = node.property("fill") { style.fill = v }
        if let v = node.property("fill-rule") { style.fillRule = v }
        if let v = node.property("stroke") { style.stroke = v }
        if let v = length(node.property("stroke-width")) { style.strokeWidth = v }
        for key in ["opacity", "fill-opacity"] {
            if let v = length(node.property(key)) { style.opacity *= v }
        }
        return style
    }
}

struct Layer {
    let path: CGPath
    let luminance: CGFloat
    let ink: Bool
}

/// Elements that are never painted where they stand.
let unpainted: Set<String> = ["defs", "clipPath", "mask", "filter", "linearGradient", "radialGradient", "pattern",
                              "symbol", "title", "desc", "metadata", "style", "image", "marker"]

func geometry(_ node: Node) -> CGPath? {
    let a = node.attributes
    let path = CGMutablePath()
    func n(_ key: String) -> CGFloat { length(a[key]) ?? 0 }
    switch node.name {
    case "path": parsePath(a["d"] ?? "", into: path)
    case "rect":
        let rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
        guard rect.width > 0, rect.height > 0 else { return nil }
        let rx = length(a["rx"]) ?? length(a["ry"]) ?? 0, ry = length(a["ry"]) ?? rx
        path.addRoundedRect(in: rect, cornerWidth: min(rx, rect.width / 2), cornerHeight: min(ry, rect.height / 2))
    case "circle":
        let r = n("r")
        path.addEllipse(in: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r))
    case "ellipse":
        path.addEllipse(in: CGRect(x: n("cx") - n("rx"), y: n("cy") - n("ry"), width: 2 * n("rx"), height: 2 * n("ry")))
    case "polygon", "polyline":
        let v = numbers(a["points"] ?? "")
        guard v.count >= 4 else { return nil }
        path.move(to: CGPoint(x: v[0], y: v[1]))
        for i in stride(from: 2, to: v.count - 1, by: 2) { path.addLine(to: CGPoint(x: v[i], y: v[i + 1])) }
        if node.name == "polygon" { path.closeSubpath() }
    case "line":
        path.move(to: CGPoint(x: n("x1"), y: n("y1")))
        path.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
    default: return nil
    }
    return path.isEmpty ? nil : path
}

final class Painter {
    let ids: [String: Node]
    var layers: [Layer] = []
    var mark: CGPath = CGMutablePath()
    let judgeByDifference: Bool

    init(ids: [String: Node], judgeByDifference: Bool) {
        self.ids = ids
        self.judgeByDifference = judgeByDifference
    }

    func paint(_ node: Node, style parentStyle: Style, transform parentTransform: CGAffineTransform, depth: Int = 0) {
        guard !unpainted.contains(node.name), depth < 20 else { return }
        if node.property("display") == "none" || node.property("visibility") == "hidden" { return }
        let style = parentStyle.inherit(node)
        var t = transform(node.attributes["transform"]).concatenating(parentTransform)
        if node.name == "use" {
            guard let href = node.attributes["xlink:href"] ?? node.attributes["href"],
                  let target = ids[String(href.drop { $0 == "#" })] else { return }
            t = CGAffineTransform(translationX: length(node.attributes["x"]) ?? 0, y: length(node.attributes["y"]) ?? 0).concatenating(t)
            if target.name == "symbol" {
                for child in target.children { paint(child, style: style, transform: t, depth: depth + 1) }
            } else {
                paint(target, style: style, transform: t, depth: depth + 1)
            }
            return
        }
        if let shape = geometry(node) {
            var placed = t
            guard let path = shape.copy(using: &placed) else { return }
            if node.name != "line", node.name != "polyline" || style.fill != nil,
               let fill = style.fill, let lum = luminance(fill, ids: ids) {
                add(path.union(path, using: style.fillRule == "evenodd" ? .evenOdd : .winding), luminance: lum, opacity: style.opacity)
            }
            if let stroke = style.stroke, let lum = luminance(stroke, ids: ids) {
                let scale = sqrt(abs(t.a * t.d - t.b * t.c))
                add(path.copy(strokingWithWidth: style.strokeWidth * scale, lineCap: .round, lineJoin: .round, miterLimit: 10),
                    luminance: lum, opacity: style.opacity)
            }
        }
        for child in node.children { paint(child, style: style, transform: t, depth: depth + 1) }
    }

    /// Adds a painted shape to the mark, or cuts it out: a shape that stands
    /// out from what it's painted on is a cut-out when that is ink, and ink
    /// when that is a cut-out.
    func add(_ path: CGPath, luminance lum: CGFloat, opacity: CGFloat) {
        guard opacity > 0.2, !path.boundingBoxOfPath.isEmpty else { return }
        let probe = samplePoint(in: path)
        let under = probe.flatMap { point in layers.last { $0.path.contains(point) } }
        let ink: Bool
        if let under {
            // Contrast ratio, as WCAG measures it: Netflix's red N on black
            // (4.4) and Dribbble's lines (1.9) stand out; Cloudflare's two
            // oranges (1.3) don't.
            let contrast = (max(lum, under.luminance) + 0.05) / (min(lum, under.luminance) + 0.05)
            let standsOut = judgeByDifference ? abs(lum - under.luminance) > 0.3 : contrast > 1.6
            ink = standsOut ? !under.ink : under.ink
        } else {
            ink = lum < 0.85
        }
        layers.append(Layer(path: path, luminance: lum, ink: ink))
        mark = ink ? mark.union(path) : mark.subtracting(path)
    }

    /// A point inside the shape, to find what it's painted on.
    func samplePoint(in path: CGPath) -> CGPoint? {
        let box = path.boundingBoxOfPath
        let center = CGPoint(x: box.midX, y: box.midY)
        if path.contains(center) { return center }
        for fx in stride(from: 0.1, through: 0.9, by: 0.1) {
            for fy in stride(from: 0.1, through: 0.9, by: 0.1) {
                let p = CGPoint(x: box.minX + box.width * fx, y: box.minY + box.height * fy)
                if path.contains(p) { return p }
            }
        }
        return nil
    }
}

func collectIDs(_ node: Node, into ids: inout [String: Node]) {
    if let id = node.attributes["id"] { ids[id] = node }
    for child in node.children { collectIDs(child, into: &ids) }
}

/// The logo as one filled mark, centred in a 24-unit grid. Marks are sized
/// by area rather than by their longest side, so a wide one like
/// Cloudflare's cloud isn't left a thin strip: a square mark is 21 units, as
/// wide as a Hugeicon's ink, and a wide one grows until it's 27 units wide,
/// a little past the grid (the app widens the image to fit), or a tall one
/// 23 units tall.
func mark(_ url: URL, byDifference: Bool) -> CGPath? {
    guard let root = parse(url) else { return nil }
    var ids: [String: Node] = [:]
    collectIDs(root, into: &ids)
    let painter = Painter(ids: ids, judgeByDifference: byDifference)
    painter.paint(root, style: Style(), transform: .identity)
    let box = painter.mark.boundingBoxOfPath
    guard !painter.mark.isEmpty, box.width > 0, box.height > 0 else { return nil }
    let scale = min(21 / (box.width * box.height).squareRoot(), 27 / box.width, 23 / box.height)
    var fit = CGAffineTransform(translationX: 12, y: 12).scaledBy(x: scale, y: scale).translatedBy(x: -box.midX, y: -box.midY)
    return painter.mark.copy(using: &fit)
}

// MARK: Catalog

struct Entry: Decodable {
    let name: String
    let shortname: String
    let files: [String]
}

let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: repo.appending(path: "logos.json")))
var lines: [String] = [], failed: [String] = [], seen = Set<String>()
for entry in entries {
    guard let file = entry.files.first(where: { $0.hasSuffix("-icon.svg") }) else { continue }
    let name = String(file.dropLast("-icon.svg".count))
    guard !skipped.contains(name), seen.insert(name).inserted else { continue }
    guard let path = mark(repo.appending(path: "logos").appending(path: file), byDifference: byDifference.contains(name)) else { failed.append(name); continue }
    let title = entry.name.replacingOccurrences(of: "\t", with: " ")
    lines.append("\(name)\tf:\(pathData(path, places: 2))\t\(title)")
}
try (lines.joined(separator: "\n") + "\n").write(to: output, atomically: true, encoding: .utf8)
print("wrote \(lines.count) brands" + (failed.isEmpty ? "" : "; couldn't draw \(failed.joined(separator: ", "))"))
