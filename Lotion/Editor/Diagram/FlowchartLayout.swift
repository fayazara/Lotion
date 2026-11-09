//
//  FlowchartLayout.swift
//  Lotion
//
//  Places a flowchart's cards and routes its wires. A layered layout: ranks
//  run along the chart's direction, cards in a rank are ordered to keep
//  wires from crossing and nudged toward the cards they connect to, and
//  every wire is made of straight runs with rounded bends.
//
//  The work is done along two axes, `u` with the ranks and `v` across them,
//  and turned into x and y at the end, so every direction shares one path.
//

import AppKit

/// Fonts and spacing for a chart's cards.
struct FlowMetrics {
    var title: NSFont
    var detail: NSFont
    var label: NSFont

    static let padding: CGFloat = 14
    static let chip: CGFloat = 28
    static let chipGap: CGFloat = 10
    static let detailGap: CGFloat = 6
    static let portRow: CGFloat = 24
    static let minWidth: CGFloat = 150
    static let maxWidth: CGFloat = 280
    static let radius: CGFloat = 14

    init(base size: CGFloat) {
        let titleSize = max(12, round(size * 0.9))
        title = .systemFont(ofSize: titleSize, weight: .medium)
        detail = .systemFont(ofSize: max(11, titleSize - 2))
        label = .systemFont(ofSize: max(10.5, titleSize - 3), weight: .medium)
    }

    func size(of text: String, font: NSFont, width: CGFloat = .greatestFiniteMagnitude) -> NSSize {
        guard !text.isEmpty else { return .zero }
        let rect = NSAttributedString(string: text, attributes: [.font: font])
            .boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        return NSSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

struct PlacedNode {
    let index: Int
    var rect: CGRect
    /// The card's height before any rows of branch labels.
    var bodyHeight: CGFloat
    /// Branch labels drawn inside the card beside their ports.
    var portLabels: [(text: String, point: CGPoint, trailing: Bool)] = []
}

struct PlacedEdge {
    let index: Int
    var points: [CGPoint]
    var labelPoint: CGPoint?
    /// Whether the wire starts at a port of its own on a branching card.
    var startsAtPort = true
}

struct PlacedGroup {
    let id: String
    var title: String
    var rect: CGRect
    var depth: Int
}

struct FlowLayout {
    var size: CGSize = .zero
    var nodes: [PlacedNode] = []
    var edges: [PlacedEdge] = []
    var groups: [PlacedGroup] = []

    static let margin: CGFloat = 28

    // MARK: - Layout

    static func make(_ chart: Flowchart, metrics: FlowMetrics) -> FlowLayout {
        var builder = Builder(chart: chart, metrics: metrics)
        return builder.run()
    }

    private struct Item {
        /// A chart node, or nil for a point a long wire passes through.
        var node: Int?
        var main: CGFloat
        var cross: CGFloat
        var rank = 0
        var u: CGFloat = 0
        var v: CGFloat = 0
        var group: String?
    }

    private struct Builder {
        let chart: Flowchart
        let metrics: FlowMetrics
        var items: [Item] = []
        /// Items in each rank, in order.
        var ranks: [[Int]] = []
        /// Edges (by index) that run against the ranks after cycles are broken.
        var reversed: Set<Int> = []
        /// For each drawn edge, the items its wire passes through.
        var chains: [Int: [Int]] = [:]
        var bodyHeights: [CGFloat] = []
        var outgoingLabels: [Int: [Int]] = [:]
        var rankStart: [CGFloat] = []
        var rankEnd: [CGFloat] = []

        var horizontal: Bool { chart.direction.isHorizontal }
        /// How far a shared trunk stands off the card it gathers wires for.
        static let trunkInset: CGFloat = 26

        init(chart: Flowchart, metrics: FlowMetrics) {
            self.chart = chart
            self.metrics = metrics
        }

        // MARK: Sizes

        /// A branching card: one with labeled wires out of it, each given a port and a row.
        func isBranch(_ node: Int) -> Bool {
            let labeled = (outgoingLabels[node] ?? []).count
            return labeled >= 2 || (labeled >= 1 && chart.nodes[node].shape == .decision)
        }

        mutating func measureNodes() {
            for (index, edge) in chart.edges.enumerated() where edge.line != .invisible && !edge.label.isEmpty && edge.from != edge.to {
                guard let from = chart.index(of: edge.from) else { continue }
                outgoingLabels[from, default: []].append(index)
            }
            let p = FlowMetrics.padding
            for (index, node) in chart.nodes.enumerated() {
                let titleRoom = FlowMetrics.maxWidth - p * 2 - FlowMetrics.chip - FlowMetrics.chipGap
                let titleSize = metrics.size(of: node.title, font: metrics.title, width: titleRoom)
                let detailNatural = metrics.size(of: node.detail, font: metrics.detail, width: FlowMetrics.maxWidth - p * 2)
                var width = max(p * 2 + FlowMetrics.chip + FlowMetrics.chipGap + titleSize.width, p * 2 + detailNatural.width)
                let labels = (outgoingLabels[index] ?? []).map { chart.edges[$0].label }
                if isBranch(index), !horizontal {
                    let total = labels.reduce(0) { $0 + metrics.size(of: $1, font: metrics.label).width + 28 }
                    width = max(width, total + p)
                }
                // Start and end pills can be small; working cards share a width floor.
                let isPill = (node.shape == .stadium || node.shape == .circle) && node.detail.isEmpty
                width = min(FlowMetrics.maxWidth, max(isPill ? 96 : FlowMetrics.minWidth, ceil(width)))
                let titleHeight = metrics.size(of: node.title, font: metrics.title,
                                               width: width - p * 2 - FlowMetrics.chip - FlowMetrics.chipGap).height
                let detailHeight = metrics.size(of: node.detail, font: metrics.detail, width: width - p * 2).height
                var height = p + max(FlowMetrics.chip, titleHeight) + (node.detail.isEmpty ? 0 : FlowMetrics.detailGap + detailHeight) + p
                height = ceil(height)
                bodyHeights.append(height)
                if isBranch(index) {
                    height += horizontal ? CGFloat(labels.count) * FlowMetrics.portRow + 4 : FlowMetrics.portRow
                }
                let size = CGSize(width: width, height: height)
                items.append(Item(node: index, main: horizontal ? size.width : size.height,
                                  cross: horizontal ? size.height : size.width, group: node.group))
            }
        }

        // MARK: Ranks

        mutating func assignRanks() {
            let count = chart.nodes.count
            var outgoing = Array(repeating: [(edge: Int, to: Int)](), count: count)
            for (index, edge) in chart.edges.enumerated() {
                guard let from = chart.index(of: edge.from), let to = chart.index(of: edge.to), from != to else { continue }
                outgoing[from].append((index, to))
            }
            // Break cycles: an edge back to a node still being visited runs against the ranks.
            var state = Array(repeating: 0, count: count)
            func visit(_ node: Int) {
                state[node] = 1
                for (edge, to) in outgoing[node] {
                    if state[to] == 1 { reversed.insert(edge) } else if state[to] == 0 { visit(to) }
                }
                state[node] = 2
            }
            // Start from nodes nothing points at, so the first-written flow runs forward.
            var hasIncoming = Array(repeating: false, count: count)
            for list in outgoing { for (_, to) in list { hasIncoming[to] = true } }
            for node in 0..<count where !hasIncoming[node] && state[node] == 0 { visit(node) }
            for node in 0..<count where state[node] == 0 { visit(node) }

            // Longest path, in topological order.
            var forward = Array(repeating: [Int](), count: count)
            var backward = Array(repeating: [Int](), count: count)
            var indegree = Array(repeating: 0, count: count)
            for (index, edge) in chart.edges.enumerated() {
                guard var from = chart.index(of: edge.from), var to = chart.index(of: edge.to), from != to else { continue }
                if reversed.contains(index) { swap(&from, &to) }
                forward[from].append(to)
                backward[to].append(from)
                indegree[to] += 1
            }
            var queue = (0..<count).filter { indegree[$0] == 0 }
            var order: [Int] = []
            var rank = Array(repeating: 0, count: count)
            while !queue.isEmpty {
                let node = queue.removeFirst()
                order.append(node)
                for next in forward[node] {
                    rank[next] = max(rank[next], rank[node] + 1)
                    indegree[next] -= 1
                    if indegree[next] == 0 { queue.append(next) }
                }
            }
            // Pull sources up to just before the first node they feed.
            for node in order.reversed() where backward[node].isEmpty && !forward[node].isEmpty {
                rank[node] = (forward[node].map { rank[$0] }.min() ?? 1) - 1
            }
            for node in 0..<count { items[node].rank = rank[node] }
        }

        /// Long wires pass through a point in every rank they cross.
        mutating func addWaypoints() {
            for (index, edge) in chart.edges.enumerated() where edge.line != .invisible {
                guard var from = chart.index(of: edge.from), var to = chart.index(of: edge.to) else { continue }
                // Loops and wires back up the chart go around the outside: no waypoints.
                if from == to || reversed.contains(index) { chains[index] = []; continue }
                var chain: [Int] = []
                let start = items[from].rank
                let end = items[to].rank
                if end - start > 1 {
                    for rank in (start + 1)..<end {
                        items.append(Item(node: nil, main: 0, cross: 0, rank: rank,
                                          group: chart.nodes[from].group == chart.nodes[to].group ? chart.nodes[from].group : nil))
                        chain.append(items.count - 1)
                    }
                }
                chains[index] = chain
            }
            let top = items.map(\.rank).max() ?? 0
            ranks = Array(repeating: [], count: top + 1)
            for (index, item) in items.enumerated() { ranks[item.rank].append(index) }
        }

        // MARK: Order

        /// Links between items in neighboring ranks, as (upper, lower).
        func segments() -> [(Int, Int)] {
            var result: [(Int, Int)] = []
            for (index, edge) in chart.edges.enumerated() where edge.line != .invisible && !reversed.contains(index) {
                guard let from = chart.index(of: edge.from), let to = chart.index(of: edge.to), from != to else { continue }
                let path = [from] + (chains[index] ?? []) + [to]
                for pair in zip(path, path.dropFirst()) { result.append(pair) }
            }
            // Invisible links still hold their ends together.
            for edge in chart.edges where edge.line == .invisible {
                guard let from = chart.index(of: edge.from), let to = chart.index(of: edge.to),
                      items[to].rank == items[from].rank + 1 else { continue }
                result.append((from, to))
            }
            return result
        }

        mutating func order() {
            let links = segments()
            var up = Array(repeating: [Int](), count: items.count)
            var down = Array(repeating: [Int](), count: items.count)
            for (a, b) in links {
                down[a].append(b)
                up[b].append(a)
            }
            var position = Array(repeating: 0.0, count: items.count)
            func index() { for rank in ranks { for (i, item) in rank.enumerated() { position[item] = Double(i) } } }
            index()
            func crossings() -> Int {
                var total = 0
                for rank in ranks {
                    var pairs: [(Double, Double)] = []
                    for item in rank { for next in down[item] { pairs.append((position[item], position[next])) } }
                    for i in 0..<pairs.count {
                        for j in (i + 1)..<max(i + 1, pairs.count) where (pairs[i].0 - pairs[j].0) * (pairs[i].1 - pairs[j].1) < 0 {
                            total += 1
                        }
                    }
                }
                return total
            }
            var best = ranks
            var bestCrossings = crossings()
            for pass in 0..<16 {
                let downward = pass % 2 == 0
                let sequence = downward ? Array(ranks.indices.dropFirst()) : Array(ranks.indices.dropLast().reversed())
                for r in sequence {
                    let keyed = ranks[r].map { item -> (Int, Double) in
                        let neighbors = downward ? up[item] : down[item]
                        guard !neighbors.isEmpty else { return (item, position[item]) }
                        let values = neighbors.map { position[$0] }.sorted()
                        let median = values.count % 2 == 1
                            ? values[values.count / 2]
                            : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
                        return (item, median)
                    }
                    ranks[r] = keyed.enumerated().sorted { ($0.element.1, $0.offset) < ($1.element.1, $1.offset) }.map(\.element.0)
                    for (i, item) in ranks[r].enumerated() { position[item] = Double(i) }
                }
                let count = crossings()
                if count < bestCrossings {
                    bestCrossings = count
                    best = ranks
                }
            }
            ranks = best
            // Keep each subgraph's members side by side.
            for r in ranks.indices {
                var mean: [String: Double] = [:]
                var counts: [String: Double] = [:]
                for (i, item) in ranks[r].enumerated() {
                    guard let group = items[item].group else { continue }
                    mean[group, default: 0] += Double(i)
                    counts[group, default: 0] += 1
                }
                ranks[r] = ranks[r].enumerated().sorted { a, b in
                    let ka = items[a.element].group.map { mean[$0]! / counts[$0]! } ?? Double(a.offset)
                    let kb = items[b.element].group.map { mean[$0]! / counts[$0]! } ?? Double(b.offset)
                    return (ka, a.offset) < (kb, b.offset)
                }.map(\.element)
            }
        }

        // MARK: Coordinates

        func separation(_ a: Int, _ b: Int) -> CGFloat {
            let gap: CGFloat = items[a].node == nil || items[b].node == nil ? 20 : (horizontal ? 36 : 44)
            let groups = items[a].group != items[b].group ? 28 : 0
            return items[a].cross / 2 + items[b].cross / 2 + gap + CGFloat(groups)
        }

        mutating func placeAcross() {
            let links = segments()
            var up = Array(repeating: [Int](), count: items.count)
            var down = Array(repeating: [Int](), count: items.count)
            for (a, b) in links {
                down[a].append(b)
                up[b].append(a)
            }
            // Centers, packed in order.
            for rank in ranks {
                var v: CGFloat = 0
                for (i, item) in rank.enumerated() {
                    if i > 0 { v += separation(rank[i - 1], item) }
                    items[item].v = v
                }
            }
            for pass in 0..<10 {
                let downward = pass % 2 == 0
                let sequence = downward ? Array(ranks.indices.dropFirst()) : Array(ranks.indices.dropLast().reversed())
                for r in sequence {
                    let rank = ranks[r]
                    guard !rank.isEmpty else { continue }
                    let desired = rank.map { item -> CGFloat in
                        let neighbors = downward ? up[item] : down[item]
                        guard !neighbors.isEmpty else { return items[item].v }
                        return neighbors.map { items[$0].v }.reduce(0, +) / CGFloat(neighbors.count)
                    }
                    // Two feasible placements, one packed from each end; their average is feasible too.
                    var forward = desired
                    for i in 1..<max(1, rank.count) {
                        forward[i] = max(desired[i], forward[i - 1] + separation(rank[i - 1], rank[i]))
                    }
                    var backward = desired
                    if rank.count > 1 {
                        for i in stride(from: rank.count - 2, through: 0, by: -1) {
                            backward[i] = min(desired[i], backward[i + 1] - separation(rank[i], rank[i + 1]))
                        }
                    }
                    for (i, item) in rank.enumerated() { items[item].v = (forward[i] + backward[i]) / 2 }
                }
            }
        }

        /// Lines up one-to-one links, so a plain chain runs straight.
        mutating func straighten() {
            let links = segments()
            var outCount = Array(repeating: 0, count: items.count)
            var inCount = Array(repeating: 0, count: items.count)
            for (a, b) in links { outCount[a] += 1; inCount[b] += 1 }
            var slot: [Int: (rank: Int, index: Int)] = [:]
            for (r, rank) in ranks.enumerated() { for (i, item) in rank.enumerated() { slot[item] = (r, i) } }
            func fits(_ item: Int, at v: CGFloat) -> Bool {
                guard let (r, i) = slot[item] else { return false }
                let rank = ranks[r]
                if i > 0, v - items[rank[i - 1]].v < separation(rank[i - 1], item) - 0.5 { return false }
                if i + 1 < rank.count, items[rank[i + 1]].v - v < separation(item, rank[i + 1]) - 0.5 { return false }
                return true
            }
            for _ in 0..<4 {
                for (a, b) in links where outCount[a] == 1 && inCount[b] == 1 && abs(items[a].v - items[b].v) > 0.5 {
                    if fits(b, at: items[a].v) {
                        items[b].v = items[a].v
                    } else if inCount[a] <= 1, fits(a, at: items[b].v) {
                        items[a].v = items[b].v
                    }
                }
            }
        }

        // MARK: Subgraphs

        /// Members of a group, nested groups' included.
        func members(of group: String) -> Set<Int> {
            var ids: Set<String> = [group]
            var grew = true
            while grew {
                grew = false
                for child in chart.groups where child.parent.map(ids.contains) == true && !ids.contains(child.id) {
                    ids.insert(child.id)
                    grew = true
                }
            }
            return Set(items.indices.filter { items[$0].node != nil && items[$0].group.map(ids.contains) == true })
        }

        func isAncestor(_ a: String, of b: String) -> Bool {
            var parent = chart.groups.first { $0.id == b }?.parent
            while let id = parent {
                if id == a { return true }
                parent = chart.groups.first { $0.id == id }?.parent
            }
            return false
        }

        /// A group's frame across the ranks (v only), with room for its title.
        func span(_ members: Set<Int>) -> (min: CGFloat, max: CGFloat, ranks: ClosedRange<Int>)? {
            guard let first = members.first else { return nil }
            var low = CGFloat.greatestFiniteMagnitude, high = -CGFloat.greatestFiniteMagnitude
            var r0 = items[first].rank, r1 = r0
            for item in members {
                low = min(low, items[item].v - items[item].cross / 2)
                high = max(high, items[item].v + items[item].cross / 2)
                r0 = min(r0, items[item].rank)
                r1 = max(r1, items[item].rank)
            }
            return (low - (horizontal ? 34 : 16), high + 16, r0...r1)
        }

        /// Moves everything from `threshold` across, except `keep`, to make room.
        mutating func push(from threshold: CGFloat, by amount: CGFloat, keep: Set<Int>) {
            for index in items.indices where !keep.contains(index) && items[index].v >= threshold {
                items[index].v += amount
            }
        }

        /// Pulls apart frames that overlap each other or cards outside them.
        mutating func separateGroups() {
            guard !chart.groups.isEmpty else { return }
            let all = chart.groups.map { (id: $0.id, members: members(of: $0.id)) }.filter { !$0.members.isEmpty }
            for _ in 0..<24 {
                var moved = false
                // Frames that overlap: the lower one moves down, with everything under it.
                for a in all {
                    for b in all where a.id != b.id && !isAncestor(a.id, of: b.id) && !isAncestor(b.id, of: a.id) {
                        guard let sa = span(a.members), let sb = span(b.members), sa.ranks.overlaps(sb.ranks),
                              sa.min <= sb.min, sb.min < sa.max + 12 else { continue }
                        let threshold = b.members.map { items[$0].v }.min() ?? 0
                        push(from: threshold, by: sa.max + 12 - sb.min, keep: a.members)
                        moved = true
                    }
                }
                // Cards inside a frame they don't belong to.
                for group in all {
                    guard let frame = span(group.members) else { continue }
                    for item in items.indices where items[item].node != nil && !group.members.contains(item) && frame.ranks.contains(items[item].rank) {
                        let top = items[item].v - items[item].cross / 2
                        let bottom = items[item].v + items[item].cross / 2
                        guard bottom > frame.min, top < frame.max else { continue }
                        if items[item].v >= (frame.min + frame.max) / 2 {
                            push(from: items[item].v, by: frame.max + 12 - top, keep: group.members)
                        } else {
                            let threshold = group.members.map { items[$0].v }.min() ?? 0
                            push(from: threshold, by: bottom + 12 - frame.min, keep: [item])
                        }
                        moved = true
                    }
                }
                if !moved { break }
            }
        }

        mutating func placeAlong() {
            // Wide labels on wires need room in the gap they are drawn in.
            var gapLabel = Array(repeating: CGFloat(0), count: ranks.count)
            for (index, edge) in chart.edges.enumerated() where !edge.label.isEmpty {
                guard let from = chart.index(of: edge.from), !isBranch(from), !reversed.contains(index) else { continue }
                let r = items[from].rank
                let size = metrics.size(of: edge.label, font: metrics.label)
                // The label sits on a straight run of its wire, clear of the trunk it shares.
                gapLabel[r] = max(gapLabel[r], (horizontal ? size.width : size.height) + 32 + Self.trunkInset * 2)
            }
            var u: CGFloat = 0
            for (r, rank) in ranks.enumerated() {
                let thickness = rank.map { items[$0].main }.max() ?? 0
                rankStart.append(u)
                rankEnd.append(u + thickness)
                for item in rank { items[item].u = u }
                u += thickness + max(horizontal ? 96 : 76, gapLabel[r])
            }
        }

        // MARK: Wires

        /// A node's rect in (u, v): u along the ranks, v across.
        func box(_ item: Int) -> CGRect {
            CGRect(x: items[item].u, y: items[item].v - items[item].cross / 2, width: items[item].main, height: items[item].cross)
        }

        mutating func run() -> FlowLayout {
            guard !chart.nodes.isEmpty else { return FlowLayout() }
            measureNodes()
            assignRanks()
            addWaypoints()
            order()
            placeAcross()
            straighten()
            separateGroups()
            placeAlong()

            var layout = FlowLayout()
            var portLabels: [Int: [(String, CGPoint, Bool)]] = [:]
            // Ports for each branching card's labeled wires, ordered by where their targets sit.
            var branchPort: [Int: CGPoint] = [:]
            for (node, edges) in outgoingLabels where isBranch(node) {
                let sorted = edges.sorted { a, b in
                    let ta = chart.index(of: chart.edges[a].to).map { items[$0].v } ?? 0
                    let tb = chart.index(of: chart.edges[b].to).map { items[$0].v } ?? 0
                    return ta < tb
                }
                let rect = box(node)
                for (i, edge) in sorted.enumerated() {
                    let point: CGPoint
                    if horizontal {
                        let v = rect.minY + bodyHeights[node] - 4 + FlowMetrics.portRow * (CGFloat(i) + 0.5)
                        point = CGPoint(x: rect.maxX, y: v)
                    } else {
                        let v = rect.minY + rect.height * CGFloat(i + 1) / CGFloat(sorted.count + 1)
                        point = CGPoint(x: rect.maxX, y: v)
                    }
                    branchPort[edge] = point
                    // Beside the port across a horizontal chart; above it in a vertical one.
                    portLabels[node, default: []].append((chart.edges[edge].label, point, horizontal))
                }
            }

            var routes: [(edge: Int, points: [CGPoint], label: CGPoint?, port: Bool, keys: [Int: String])] = []
            // How many forward wires meet at each card, for bundling.
            var incoming: [Int: Int] = [:]
            var outgoing: [Int: Int] = [:]
            for (index, edge) in chart.edges.enumerated() where edge.line != .invisible && !reversed.contains(index) {
                guard let from = chart.index(of: edge.from), let to = chart.index(of: edge.to), from != to else { continue }
                incoming[to, default: 0] += 1
                outgoing[from, default: 0] += 1
            }
            var backLanes = 0
            var aboveLanes = 0
            let crossMax = items.map { $0.v + $0.cross / 2 }.max() ?? 0

            for (index, edge) in chart.edges.enumerated() where edge.line != .invisible {
                guard let from = chart.index(of: edge.from), let to = chart.index(of: edge.to) else { continue }
                let source = box(from)
                let target = box(to)
                let start = branchPort[index] ?? CGPoint(x: source.maxX, y: source.midY)
                let end = CGPoint(x: target.minX, y: target.midY)
                if from == to || reversed.contains(index) {
                    // Around the outside: out the far side, along the edge of the chart, in the near side.
                    let lane: CGFloat
                    if from == to {
                        aboveLanes += 1
                        lane = source.minY - 18 - CGFloat(aboveLanes - 1) * 8
                    } else {
                        backLanes += 1
                        lane = crossMax + 28 + CGFloat(backLanes - 1) * 12
                    }
                    let out = start.x + 20
                    let back = end.x - 20
                    let points = [start, CGPoint(x: out, y: start.y), CGPoint(x: out, y: lane), CGPoint(x: back, y: lane),
                                  CGPoint(x: back, y: end.y), end]
                    let label = edge.label.isEmpty || branchPort[index] != nil ? nil : CGPoint(x: (out + back) / 2, y: lane)
                    routes.append((index, points, label, branchPort[index] != nil, [:]))
                    continue
                }
                // Through each waypoint. Wires into a card that several feed share a
                // trunk just before it and arrive as one; wires out of a card that
                // feeds several share a trunk just after it.
                var stops: [(u0: CGFloat, u1: CGFloat, v: CGFloat)] = [(start.x, start.x, start.y)]
                for item in chains[index] ?? [] {
                    let r = items[item].rank
                    stops.append((rankStart[r], rankEnd[r], items[item].v))
                }
                stops.append((end.x, end.x, end.y))
                let fanIn = (incoming[to] ?? 0) >= 2
                let fanOut = branchPort[index] == nil && (outgoing[from] ?? 0) >= 2
                let sourceGapStart = rankEnd[items[from].rank]
                let targetGapEnd = rankStart[items[to].rank]
                var points: [CGPoint] = [start]
                var keys: [Int: String] = [:]
                var label: CGPoint?
                let gaps = Array(zip(stops, stops.dropFirst()))
                for (g, (a, b)) in gaps.enumerated() {
                    let first = g == 0, last = g == gaps.count - 1
                    let gapStart = first ? sourceGapStart : a.u1
                    let gapEnd = last ? targetGapEnd : b.u0
                    let trunk: CGFloat
                    let key: String
                    if last && fanIn {
                        trunk = gapEnd - Self.trunkInset
                        key = "in:\(to)"
                    } else if first && fanOut {
                        trunk = gapStart + Self.trunkInset
                        key = "out:\(from)@\(Int(start.y))"
                    } else {
                        trunk = ((gapStart + gapEnd) / 2).rounded()
                        key = "edge:\(index):\(g)"
                    }
                    if abs(a.v - b.v) < 0.5 {
                        points.append(CGPoint(x: b.u0, y: b.v))
                    } else {
                        points.append(CGPoint(x: trunk, y: a.v))
                        keys[points.count - 1] = key
                        points.append(CGPoint(x: trunk, y: b.v))
                        points.append(CGPoint(x: b.u0, y: b.v))
                    }
                    if b.u1 > b.u0 { points.append(CGPoint(x: b.u1, y: b.v)) }
                    // The label rides the straight run that is this wire's alone.
                    if first, !edge.label.isEmpty, branchPort[index] == nil {
                        if abs(a.v - b.v) < 0.5 {
                            label = CGPoint(x: ((start.x + gapEnd) / 2).rounded(), y: a.v)
                        } else if last && fanIn && (outgoing[from] ?? 0) >= 2 {
                            // The run out of the card is shared; the climb to the trunk is not.
                            label = CGPoint(x: trunk, y: ((a.v + b.v) / 2).rounded())
                        } else if last && fanIn {
                            label = CGPoint(x: ((start.x + trunk) / 2).rounded(), y: a.v)
                        } else {
                            label = CGPoint(x: ((trunk + gapEnd) / 2).rounded(), y: b.v)
                        }
                    }
                }
                routes.append((index, points, label, branchPort[index] != nil, keys))
            }

            // Trunks that would land on the same line but carry different wires
            // move apart into lanes; wires in one bundle stay together.
            var gapMembers: [Int: [String]] = [:]
            for route in routes {
                for (j, key) in route.keys.sorted(by: { $0.key < $1.key }) {
                    let x = Int(route.points[j].x.rounded())
                    if !gapMembers[x, default: []].contains(key) { gapMembers[x, default: []].append(key) }
                }
            }
            for i in routes.indices {
                var points = routes[i].points
                for (j, key) in routes[i].keys {
                    let members = gapMembers[Int(points[j].x.rounded())] ?? []
                    guard members.count > 1, let lane = members.firstIndex(of: key) else { continue }
                    let offset = (CGFloat(lane) - CGFloat(members.count - 1) / 2) * 12
                    points[j].x += offset
                    points[j + 1].x += offset
                }
                routes[i].points = points
            }

            // Turn (u, v) into (x, y).
            let totalMain = (rankEnd.last ?? 0)
            func place(_ p: CGPoint) -> CGPoint {
                let u = chart.direction.isReversed ? totalMain - p.x : p.x
                return horizontal ? CGPoint(x: u, y: p.y) : CGPoint(x: p.y, y: u)
            }
            func place(_ r: CGRect) -> CGRect {
                let a = place(CGPoint(x: r.minX, y: r.minY))
                let b = place(CGPoint(x: r.maxX, y: r.maxY))
                return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }

            for node in chart.nodes.indices {
                var placed = PlacedNode(index: node, rect: place(box(node)), bodyHeight: bodyHeights[node])
                placed.portLabels = (portLabels[node] ?? []).map { ($0.0, place($0.1), $0.2) }
                layout.nodes.append(placed)
            }
            for route in routes {
                layout.edges.append(PlacedEdge(index: route.edge, points: route.points.map(place), labelPoint: route.label.map(place),
                                               startsAtPort: route.port))
            }

            // Subgraphs: the box around their members, nested ones inside.
            func members(_ group: String) -> [CGRect] {
                var rects = layout.nodes.filter { chart.nodes[$0.index].group == group }.map(\.rect)
                for child in chart.groups where child.parent == group { rects += members(child.id).map { $0.insetBy(dx: -14, dy: -14) } }
                return rects
            }
            func depth(_ group: FlowGroup) -> Int {
                var depth = 0
                var parent = group.parent
                while let id = parent { depth += 1; parent = chart.groups.first { $0.id == id }?.parent }
                return depth
            }
            for group in chart.groups {
                let rects = members(group.id)
                guard let first = rects.first else { continue }
                let union = rects.dropFirst().reduce(first) { $0.union($1) }
                let rect = CGRect(x: union.minX - 16, y: union.minY - 34, width: union.width + 32, height: union.height + 50)
                layout.groups.append(PlacedGroup(id: group.id, title: group.title, rect: rect, depth: depth(group)))
            }
            layout.groups.sort { $0.depth < $1.depth }

            // Everything inside the margin.
            var bounds = layout.nodes.map(\.rect).reduce(CGRect.null) { $0.union($1) }
            for edge in layout.edges { for point in edge.points { bounds = bounds.union(CGRect(origin: point, size: .zero)) } }
            for group in layout.groups { bounds = bounds.union(group.rect) }
            for edge in layout.edges {
                guard let point = edge.labelPoint else { continue }
                let size = metrics.size(of: chart.edges[edge.index].label, font: metrics.label)
                bounds = bounds.union(CGRect(x: point.x - size.width / 2 - 8, y: point.y - size.height / 2 - 4,
                                             width: size.width + 16, height: size.height + 8))
            }
            let dx = margin - bounds.minX
            let dy = margin - bounds.minY
            for i in layout.nodes.indices {
                layout.nodes[i].rect = layout.nodes[i].rect.offsetBy(dx: dx, dy: dy)
                layout.nodes[i].portLabels = layout.nodes[i].portLabels.map { ($0.text, CGPoint(x: $0.point.x + dx, y: $0.point.y + dy), $0.trailing) }
            }
            for i in layout.edges.indices {
                layout.edges[i].points = layout.edges[i].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
                layout.edges[i].labelPoint = layout.edges[i].labelPoint.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
            }
            for i in layout.groups.indices { layout.groups[i].rect = layout.groups[i].rect.offsetBy(dx: dx, dy: dy) }
            layout.size = CGSize(width: ceil(bounds.width + margin * 2), height: ceil(bounds.height + margin * 2))
            return layout
        }
    }
}
