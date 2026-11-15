// Converts Hugeicons (free, stroke-rounded, 24×24 grid, from @hugeicons/core-free-icons'
// ESM data files) into custom SF Symbol templates: strokes are outlined with CoreGraphics
// and unioned, then placed on the Regular-M guides of an SF Symbols template.
//
// Scripts/hugeicons.tsv maps each SF Symbol name the app uses to a Hugeicon (a third
// column of `fill` makes a solid version). To add or change an icon, edit the table and run:
//
//   npm pack @hugeicons/core-free-icons && tar xzf hugeicons-core-free-icons-*.tgz
//   swift Scripts/hugeicons.swift package/dist/esm Scripts/hugeicons.tsv \
//       Lotion/Assets.xcassets/Hugeicons Lotion/Design/Hugeicons.swift \
//       Lotion/Design/Hugeicons.txt
//
// The last file is the whole free set, which the icon picker searches.
//
// Browse names at https://hugeicons.com/icons?style=Stroke&type=Rounded (free set only).
import CoreGraphics
import Foundation

let args = CommandLine.arguments
let esm = URL(fileURLWithPath: args[1])
let mapLines = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n")
let out = URL(fileURLWithPath: args[3])
let table = URL(fileURLWithPath: args[4])

// MARK: SVG path parsing

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

/// Hugeicons draw 1.5 on a 24 grid; a touch heavier sits better beside text in the app (1.75).
let strokeBoost: CGFloat = 1.75 / 1.5

// MARK: Icon data

func attributes(_ s: Substring) -> [String: String] {
    var result: [String: String] = [:]
    let regex = try! NSRegularExpression(pattern: #"(\w+): "([^"]*)""#)
    let str = String(s)
    for m in regex.matches(in: str, range: NSRange(str.startIndex..., in: str)) {
        result[String(str[Range(m.range(at: 1), in: str)!])] = String(str[Range(m.range(at: 2), in: str)!])
    }
    return result
}

/// One drawn element of an icon, in its 24-unit grid.
struct Element {
    var path: CGPath
    /// The stroke width, if it's stroked.
    var stroke: CGFloat?
    var fill: Bool
    var evenOdd: Bool
}

func number(_ attrs: [String: String], _ key: String, _ fallback: CGFloat = 0) -> CGFloat {
    attrs[key].flatMap { Double($0) }.map { CGFloat($0) } ?? fallback
}

func elements(file: URL) -> [Element] {
    let js = try! String(contentsOf: file, encoding: .utf8)
    var result: [Element] = []
    for line in js.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[\"") else { continue }
        let tag = trimmed.dropFirst(2).prefix { $0 != "\"" }
        let attrs = attributes(Substring(trimmed))
        let element = CGMutablePath()
        switch tag {
        case "path": parsePath(attrs["d"]!, into: element)
        case "circle":
            let cx = number(attrs, "cx"), cy = number(attrs, "cy"), r = number(attrs, "r")
            element.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        case "ellipse":
            let cx = number(attrs, "cx"), cy = number(attrs, "cy"), rx = number(attrs, "rx"), ry = number(attrs, "ry")
            element.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry))
        case "rect":
            let rect = CGRect(x: number(attrs, "x"), y: number(attrs, "y"), width: number(attrs, "width"), height: number(attrs, "height"))
            let rx = number(attrs, "rx", number(attrs, "ry")), ry = number(attrs, "ry", rx)
            element.addRoundedRect(in: rect, cornerWidth: min(rx, rect.width / 2), cornerHeight: min(ry, rect.height / 2))
        default: fatalError("unsupported element \(tag) in \(file.lastPathComponent)")
        }
        var transform = CGAffineTransform.identity
        if let m = attrs["transform"] {
            let v = m.drop { $0 != "(" }.dropFirst().prefix { $0 != ")" }
                .split(whereSeparator: { $0 == " " || $0 == "," }).map { CGFloat(Double($0)!) }
            if m.hasPrefix("matrix") {
                transform = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            } else if m.hasPrefix("rotate") {
                let angle = v[0] * .pi / 180, cx = v.count > 2 ? v[1] : 0, cy = v.count > 2 ? v[2] : 0
                transform = CGAffineTransform(translationX: cx, y: cy).rotated(by: angle).translatedBy(x: -cx, y: -cy)
            } else {
                fatalError("unsupported transform \(m) in \(file.lastPathComponent)")
            }
        }
        let stroke = attrs["stroke"] != nil ? number(attrs, "strokeWidth", 1.5) : nil
        result.append(Element(path: element.copy(using: &transform)!, stroke: stroke,
                              fill: attrs["fill"] == "currentColor" || stroke == nil,
                              evenOdd: attrs["fillRule"] == "evenodd"))
    }
    return result
}

func iconFile(_ icon: String) -> URL {
    let file = esm.appending(path: "\(icon)Icon.js")
    return FileManager.default.fileExists(atPath: file.path) ? file : esm.appending(path: "\(icon).js")
}

func outline(icon: String, solid: Bool) -> CGPath {
    var shape: CGPath? = nil
    for element in elements(file: iconFile(icon)) {
        var piece = element.path
        if let width = element.stroke {
            piece = element.path.copy(strokingWithWidth: width * strokeBoost, lineCap: .round, lineJoin: .round, miterLimit: 10)
            if element.fill || solid { piece = piece.union(element.path, using: element.evenOdd ? .evenOdd : .winding) }
        }
        shape = shape.map { $0.union(piece) } ?? piece.union(piece)
    }
    return shape!
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

// MARK: Template

// The 24-unit grid is drawn 24 × `scale` units wide at the medium image scale (point
// size 100), centred on the cap height. Small and large are the same glyph resized,
// in the proportions SF Symbols use.
let scale: CGFloat = 4.6
let capHeight: CGFloat = 70.459
let leftMargin: CGFloat = 1401.84
let width: CGFloat = 24 * scale

let imageScales: [(name: String, factor: CGFloat, baseline: CGFloat)] = [("S", 0.783, 696), ("M", 1, 1126), ("L", 1.29, 1556)]

let guide = "fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"
let margin = "fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;"

func template(_ paths: [String]) -> String {
    let margins = imageScales.map { size in
        let right = fmt(leftMargin + width * size.factor), top = fmt(size.baseline - 95.21), bottom = fmt(size.baseline + 24.12)
        return """
          <line id="left-margin-Regular-\(size.name)" style="\(margin)" x1="\(fmt(leftMargin))" x2="\(fmt(leftMargin))" y1="\(top)" y2="\(bottom)"/>
          <line id="right-margin-Regular-\(size.name)" style="\(margin)" x1="\(right)" x2="\(right)" y1="\(top)" y2="\(bottom)"/>
        """
    }.joined(separator: "\n")
    let symbols = zip(imageScales, paths).map { size, d in
        """
          <g id="Regular-\(size.name)" transform="matrix(1 0 0 1 \(fmt(leftMargin)) \(fmt(size.baseline)))">
           <path d="\(d)"/>
          </g>
        """
    }.joined(separator: "\n")
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <!--glyph: "", point size: 100.0, template writer version: "101". Icon from Hugeicons (MIT), https://hugeicons.com -->
     <g id="Notes">
      <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
     </g>
     <g id="Guides">
      <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 696)"></g>
      <line id="Baseline-S" style="\(guide)" x1="263" x2="3036" y1="696" y2="696"/>
      <line id="Capline-S" style="\(guide)" x1="263" x2="3036" y1="625.541" y2="625.541"/>
      <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 1126)"></g>
      <line id="Baseline-M" style="\(guide)" x1="263" x2="3036" y1="1126" y2="1126"/>
      <line id="Capline-M" style="\(guide)" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
      <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 1556)"></g>
      <line id="Baseline-L" style="\(guide)" x1="263" x2="3036" y1="1556" y2="1556"/>
      <line id="Capline-L" style="\(guide)" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
    \(margins)
     </g>
     <g id="Symbols">
    \(symbols)
     </g>
    </svg>

    """
}

let fm = FileManager.default
try? fm.removeItem(at: out)
try fm.createDirectory(at: out, withIntermediateDirectories: true)
try #"{"info":{"author":"xcode","version":1},"properties":{"provides-namespace":false}}"#
    .write(to: out.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

var done = Set<String>()
for line in mapLines {
    let columns = line.split(separator: "\t")
    let icon = String(columns[1]), solid = columns.count > 2 && columns[2] == "fill"
    let asset = assetName(icon) + (solid ? "-fill" : "")
    guard done.insert(asset).inserted else { continue }
    let shape = outline(icon: icon, solid: solid)
    let paths = imageScales.map { size in
        var transform = CGAffineTransform(translationX: 0, y: -capHeight / 2)
            .scaledBy(x: scale * size.factor, y: scale * size.factor).translatedBy(x: 0, y: -12)
        return pathData(shape.copy(using: &transform)!)
    }
    let dir = out.appending(path: "\(asset).symbolset")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    try template(paths).write(to: dir.appending(path: "\(asset).svg"), atomically: true, encoding: .utf8)
    try #"{"info":{"author":"xcode","version":1},"symbols":[{"filename":"\#(asset).svg","idiom":"universal"}]}"#
        .write(to: dir.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
}
var entries: [String] = []
for line in mapLines {
    let columns = line.split(separator: "\t")
    let asset = assetName(String(columns[1])) + (columns.count > 2 && columns[2] == "fill" ? "-fill" : "")
    entries.append("        \"\(columns[0])\": \"\(asset)\",")
}
try """
//
//  Hugeicons.swift
//  Lotion
//
//  Generated by Scripts/hugeicons.swift from Scripts/hugeicons.tsv — don't edit by hand.
//  Which Hugeicon (a custom symbol in Assets.xcassets/Hugeicons) stands in for each
//  SF Symbol name. Icons by Hugeicons (https://hugeicons.com), MIT licensed.
//

enum Hugeicons {
    static let symbols: [String: String] = [
\(entries.joined(separator: "\n"))
    ]
}

""".write(to: table, atomically: true, encoding: .utf8)
print("wrote \(done.count) symbols, \(entries.count) mappings")

// The whole free set, for the icon picker's search: one icon per line, as
// `name<TAB>element;element…`. An element is its flags (s stroked, f filled,
// e even-odd), its stroke width when that isn't 1.5, a colon, then its path
// on the 24-unit grid with only M, L, Q, C and Z.
if args.count > 5 {
    let names = try fm.contentsOfDirectory(atPath: esm.path).filter { $0.hasSuffix("Icon.js") }.sorted()
    var seen = Set<String>(), lines: [String] = []
    for file in names {
        let name = String(assetName(String(file.dropLast(3))).dropFirst("huge.".count))
        guard seen.insert(name).inserted else { continue }
        let parts = elements(file: esm.appending(path: file)).map { element in
            var flags = (element.stroke != nil ? "s" : "") + (element.fill ? "f" : "") + (element.evenOdd ? "e" : "")
            if let width = element.stroke, width != 1.5 { flags += fmt(width, places: 2) }
            return flags + ":" + pathData(element.path, places: 2)
        }
        lines.append(name + "\t" + parts.joined(separator: ";"))
    }
    try (lines.joined(separator: "\n") + "\n").write(to: URL(fileURLWithPath: args[5]), atomically: true, encoding: .utf8)
    print("wrote \(lines.count) icons to the catalog")
}

/// `ArrowDown01` → `huge.arrow-down-01`
func assetName(_ icon: String) -> String {
    var name = icon.hasSuffix("Icon") && icon != "Icon" ? String(icon.dropLast(4)) : icon
    if name.isEmpty { name = icon }
    var result = ""
    var previous: Character? = nil
    for c in name {
        if let previous, (c.isUppercase && !previous.isUppercase) || (c.isNumber && !previous.isNumber) { result.append("-") }
        result.append(c.lowercased().first!)
        previous = c
    }
    return "huge.\(result)"
}
