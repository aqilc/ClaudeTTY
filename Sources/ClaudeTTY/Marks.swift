import AppKit


private enum Shape { case dot(x: Double, y: Double, d: Double), oval(x: Double, y: Double, w: Double, h: Double), ring(d: Double, w: Double),
    quill(outline: Double, stem: Double, rot: Double, dx: Double, dy: Double) }
private struct Motion { let name: String, inTime: Double, loopTime: Double, yellow: Bool, pose: (Double) -> [Shape], loop: (Double) -> [Shape]
    var outTime: Double? = nil, out: ((Double) -> [Shape])? = nil }
private struct Phase { let frames: Int, dots: [[[Double]]] }

private let base = 6.5
private func clamp(_ u: Double) -> Double { min(max(u, 0), 1) }
private func smooth(_ u: Double) -> Double { let v = clamp(u); return v * v * (3 - 2 * v) }
private func inOut(_ u: Double) -> Double { let v = clamp(u); return v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2 }
private func back(_ u: Double) -> Double { let v = clamp(u), c = 1.6; return 1 + (c + 1) * pow(v - 1, 3) + c * pow(v - 1, 2) }
private func osc(_ t: Double) -> Double { (1 - cos(2 * .pi * t)) / 2 }
private func lerp(_ a: Double, _ b: Double, _ u: Double) -> Double { a + (b - a) * u }
private func span(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp((t - a) / (b - a)) }

private func split(_ u: Double, y: Double = 0, x: Double = 15, side: Double = 8, mid: Double = 5.5) -> [Shape] {
    let e = back(span(u, 0.25, 1)), swell = osc(span(u, 0, 0.5) / 2)
    return [-1.0, 0, 1].map { k in .dot(x: k * x * e, y: y * smooth(u / 0.35), d: k == 0 ? lerp(base + swell, mid, e) : lerp(base, side, e)) }
}

private func sample(_ keys: [[Double]], _ f: Double, end: [Double]) -> [Double] {
    let k = keys + [end], i = min(k.lastIndex { $0[0] <= f } ?? 0, k.count - 2), a = k[i], b = k[i + 1], dt = b[0] - a[0], u = clamp((f - a[0]) / dt)
    func slope(_ j: Int, _ v: Int) -> Double { let p = k[max(j - 1, 0)], q = k[min(j + 1, k.count - 1)]; return (q[v] - p[v]) / (q[0] - p[0]) }
    let h00 = 2 * u * u * u - 3 * u * u + 1, h10 = u * u * u - 2 * u * u + u, h01 = 3 * u * u - 2 * u * u * u, h11 = u * u * u - u * u
    return (1..<a.count).map { a[$0] * h00 + slope(i, $0) * dt * h10 + b[$0] * h01 + slope(i + 1, $0) * dt * h11 }
}

private let slower = 1.05
private let seams = ["think": [54.0], "code": [18, 37, 56], "background": [18, 37, 56]]
private func tracked(_ name: String, _ phases: [Phase]) -> Motion {
    func shapes(_ p: Int, _ u: Double) -> [Shape] {
        let ph = phases[p], n = Double(ph.frames), f = u * n
        let rest = p == 0 ? clamp(1 - f / 3) : p == 2 ? clamp((f - n + 3) / 3) : 0
        return ph.dots.map { keys in
            let last = keys.last!
            let end = p == 2 ? last : phases[1].dots.map { $0[0] }.min { hypot($0[1] - last[1], $0[2] - last[2]) < hypot($1[1] - last[1], $1[2] - last[2]) }!
            let v = sample(keys, f, end: [n] + end.dropFirst()).enumerated().map { i, x in lerp(x * (i < 2 ? 0.96 : 1.05), i < 2 ? 0 : base, rest) }
            return v.count == 4 ? .oval(x: v[0], y: v[1], w: max(v[2], 0), h: max(v[3], 0)) : .dot(x: v[0], y: v[1], d: max(v[2], 0))
        }
    }
    return Motion(name: name, inTime: Double(phases[0].frames) / 30 * slower, loopTime: Double(phases[1].frames) / 30 * slower, yellow: false,
                    pose: { shapes(0, $0) }, loop: { shapes(1, $0) }, outTime: Double(phases[2].frames) / 30 * slower, out: { shapes(2, $0) })
}

private let featherIn: [[Double]] = [[0, 6.5, 0, 0], [3, 4.5, 0, 0], [3.9, 0, 0, 0], [5, 0, 0.12, 0], [7.5, 0, 0.3, 0.15], [10, 0, 0.62, 0.6], [12.5, 0, 0.9, 0.95], [15, 0, 1, 1]]
private let featherOut: [[Double]] = [[0, 0, 1, 1], [0.5, 0, 0.92, 1], [3, 0, 0.6, 0.6], [5.5, 0, 0.3, 0.15], [8, 0, 0.12, 0], [9.4, 0, 0, 0], [9.5, 4.5, 0, 0], [11, 6.5, 0, 0]]
private let featherSway: [[Double]] = [[0, 4.6, -0.5, -51], [2, 4.6, -0.8, -50], [4, 4.6, -1.5, -48], [7, 4.0, -2.1, -46], [9, 2.9, -2.0, -43], [12, 1.5, -1.6, -43],
    [14, 0.3, -1.1, -46], [17, -0.5, -0.8, -49], [19, -0.6, -0.9, -51], [22, -0.3, -1.2, -52], [24, 0.2, -1.6, -50], [27, 0.6, -1.5, -49], [29, 0.9, -1.1, -51],
    [32, 1.2, -0.8, -53], [34, 1.5, -1.1, -53], [37, 2.0, -1.4, -51], [39, 2.4, -1.4, -49], [42, 2.6, -1.2, -51], [44, 2.8, -0.9, -52], [47, 3.1, -0.9, -53],
    [49, 3.6, -1.3, -51], [52, 4.1, -1.2, -49], [54, 4.4, -0.9, -50], [57, 4.7, -0.7, -51], [59, 4.8, -0.6, -51]].map { [$0[0], $0[1] - 4.6, $0[2] + 0.5, $0[3] + 51] }
private func feather(_ track: [[Double]], _ u: Double, frames: Double) -> [Shape] {
    let v = sample(track, u * frames, end: [frames] + track.last!.dropFirst())
    return (v[0] > 0.3 ? [.dot(x: 0, y: 0, d: v[0] * 1.05)] : []) + (v[1] > 0.005 ? [.quill(outline: clamp(v[1]), stem: clamp(v[2]), rot: 0, dx: 0, dy: 0)] : [])
}

private let motions: [Motion] = [
    Motion(name: "default", inTime: 0.5, loopTime: 1.4, yellow: false, pose: { split($0) }, loop: { t in
        let p = inOut(osc(t))
        return [.dot(x: -15 + 4.5 * p, y: 0, d: 8 - 2.2 * p), .dot(x: 0, y: -1.3 * p, d: 5.5 + 2.6 * p), .dot(x: 15 - 4.5 * p, y: 0, d: 8 - 2.2 * p)]
    }),
    tracked("think", thinkKeys),
    tracked("search", searchKeys),
    tracked("read", readKeys),
    tracked("write", writeKeys),
    tracked("code", codeKeys),
    tracked("background", codeKeys),
    Motion(name: "compose", inTime: 16 / 30 * slower, loopTime: 62 / 30 * slower, yellow: false, pose: { feather(featherIn, $0, frames: 16) }, loop: { t in
        let v = sample(featherSway, t * 62, end: [62] + featherSway[0].dropFirst())
        return [.quill(outline: 1, stem: 1, rot: v[2], dx: v[0], dy: v[1])]
    }, outTime: 12 / 30 * slower, out: { feather(featherOut, $0, frames: 12) }),
    Motion(name: "blocked", inTime: 0.5, loopTime: 2.4, yellow: true, pose: { u in
        [.dot(x: 0, y: 0, d: lerp(base, 21, back(span(u, 0.15, 1)))), .ring(d: lerp(base, 34, back(span(u, 0, 0.85))), w: lerp(0.8, 2.3, smooth(u)))]
    }, loop: { t in [.dot(x: 0, y: 0, d: 21), .ring(d: 34 + 1.8 * inOut(osc(t)), w: 2.3)] }),
]

private func catmull(_ p: [(Double, Double)], _ n: Int = 8) -> [(Double, Double)] {
    [p[0]] + (0..<p.count - 1).flatMap { i in (1...n).map { s in
        let a = p[max(i - 1, 0)], b = p[i], c = p[i + 1], d = p[min(i + 2, p.count - 1)], t = Double(s) / Double(n)
        func h(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double { 0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t * t + (3 * b - a - 3 * c + d) * t * t * t) }
        return (h(a.0, b.0, c.0, d.0), h(a.1, b.1, c.1, d.1)) } }
}
private let featherOutline = catmull([(-4, 3), (-1, -5), (1, -12.5), (7.7, -16.3), (13.4, -15.4), (17.8, -9.6), (18.2, -3), (13.4, 1.0), (16.3, 4.3), (13.4, 7.7), (4.8, 9.6), (-6, 9.6)])
private let featherStem = catmull([(-12.5, 18.7), (-4.8, 7.7), (10.6, -8.6)])
private func part(_ p: [(Double, Double)], _ from: Double, _ to: Double) -> [(Double, Double)] {
    let seg = zip(p, p.dropFirst()).map { hypot($1.0 - $0.0, $1.1 - $0.1) }, total = seg.reduce(0, +)
    func at(_ s: Double) -> (Double, Double) {
        var rest = s * total
        for (i, l) in seg.enumerated() {
            if rest <= l || i == seg.count - 1 { let u = l > 0 ? min(rest / l, 1) : 0; return (lerp(p[i].0, p[i + 1].0, u), lerp(p[i].1, p[i + 1].1, u)) }
            rest -= l
        }
        return p.last!
    }
    var acc = 0.0
    let inner = zip(p.dropFirst(), seg).compactMap { pt, l -> (Double, Double)? in acc += l; return acc / total > from && acc / total < to ? pt : nil }
    return [at(from)] + inner + [at(to)]
}


final class Marks {
    let layer = CAShapeLayer()
    private struct Track { let frames: [[Shape]], paths: [CGPath] }
    private struct Segment { let name: String, loop: Bool, begin: CFTimeInterval, track: Track }
    private static var tracks: [String: (into: Track, loop: Track, out: Track)] = [:]
    private static let amber = CGColor(srgbRed: 242 / 255, green: 180 / 255, blue: 78 / 255, alpha: 1)
    private static let grey = CGColor(srgbRed: 138 / 255, green: 138 / 255, blue: 144 / 255, alpha: 1)
    private let selected: Bool
    private let delay: Double
    private var segments: [Segment] = []
    private(set) var target: String?
    private var left: Segment?
    private var hold: Timer?
    private var queued: String?
    private var latest = ""
    private var shown: CFTimeInterval = 0
    private let key: String
    private static var carried: [String: (target: String?, left: Segment?, segments: [Segment], shown: CFTimeInterval)] = [:]

    init(selected: Bool, phase: Int, key: String) {
        self.selected = selected
        self.key = key
        delay = Double(phase) * 0.15
        layer.actions = ["path": NSNull(), "fillColor": NSNull()]
        guard let was = Self.carried[key] else { return }
        (target, left, segments, shown) = was
        apply()
    }

    static func forget(_ key: String) { carried[key] = nil }

    func settle(_ done: @escaping () -> Void) {
        hold?.invalidate()
        queued = nil
        let now = layer.convertTime(CACurrentMediaTime(), from: nil), (top, frame) = top(at: now)
        let fold = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : fold(top.map { $0.track.frames[frame] } ?? [.dot(x: 0, y: 0, d: base)], top?.name ?? "default", at: now)
        target = nil
        segments = fold.map { [$0] } ?? []
        apply()
        Self.forget(key)
        hold = Timer.scheduledTimer(withTimeInterval: Double(fold?.track.frames.count ?? 0) / 60, repeats: false) { _ in done() }
    }

    deinit { hold?.invalidate() }

    func show(_ name: String) {
        latest = name
        if queued != nil, name == "think" { return }
        hold?.invalidate()
        hold = nil
        queued = nil
        guard name != target else { return }
        let wait = shown - 0.2 - layer.convertTime(CACurrentMediaTime(), from: nil)
        if target == nil || target == "think" || wait <= 0 || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return play(name) }
        queued = name
        hold = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [unowned self] _ in
            queued = nil
            play(name)
            if latest != name { show(latest) }
        }
    }

    private func play(_ name: String) {
        let now = layer.convertTime(CACurrentMediaTime(), from: nil), next = Self.track(name)
        target = name
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            segments = [Segment(name: name, loop: true, begin: now, track: Track(frames: [next.loop.frames[0]], paths: [next.loop.paths[0]]))]
            return apply()
        }
        if segments.isEmpty {
            segments = [Segment(name: name, loop: false, begin: now + delay, track: next.into), Segment(name: name, loop: true, begin: now + delay + Double(next.into.frames.count) / 60, track: next.loop)]
            return apply()
        }
        let (top, frame) = self.top(at: now)
        let current = top.map { $0.track.frames[frame] } ?? [.dot(x: 0, y: 0, d: base)]
        if let top, top.loop, top.name == name {
            segments = [top]
            return apply()
        }
        if top?.loop != true, let left, left.name == name, let blend = blend(current, into: left, at: now) {
            segments = [left, blend]
            return apply()
        }
        let leave: Segment
        if let loop = top?.loop == true ? top : segments.last.flatMap({ $0.loop ? $0 : nil }) {
            left = loop
            let length = Double(loop.track.frames.count) / 60, start = max(now, loop.begin), at = (start - loop.begin).truncatingRemainder(dividingBy: length)
            let seam = (seams[loop.name] ?? []).map { $0 / 30 * slower }.first { $0 > at + 0.05 } ?? length
            leave = Segment(name: loop.name, loop: false, begin: start - at + seam, track: Self.track(loop.name).out)
            segments = loop.begin <= now ? [loop] : segments
        } else {
            leave = fold(current, top?.name ?? name, at: now)
            segments = []
        }
        let grow = Segment(name: name, loop: false, begin: leave.begin + Double(leave.track.frames.count) / 60, track: next.into)
        segments += [leave, grow, Segment(name: name, loop: true, begin: grow.begin + Double(grow.track.frames.count) / 60, track: next.loop)]
        apply()
    }

    private func top(at time: CFTimeInterval) -> (Segment?, Int) {
        for segment in segments.reversed() where segment.begin <= time {
            let frame = Int((time - segment.begin) * 60), count = segment.track.frames.count
            if segment.loop { return (segment, frame % count) }
            if frame < count { return (segment, frame) }
        }
        return (nil, 0)
    }

    private func fold(_ shapes: [Shape], _ name: String, at time: CFTimeInterval) -> Segment {
        let spread = shapes.map { shape -> Double in
            switch shape {
            case let .dot(x, y, d): hypot(x, y) + abs(d - base) / 2
            case let .oval(x, y, w, h): hypot(x, y) + max(abs(w - base), abs(h - base)) / 2
            case let .ring(d, _): (d - base) / 2
            case .quill: 30
            }
        }.max() ?? 0
        let count = 6 + Int(clamp(spread / 30) * 18)
        return Segment(name: name, loop: false, begin: time, track: Self.track((1...count).map { index in
            let u = inOut(Double(index) / Double(count))
            return shapes.flatMap { shape -> [Shape] in
                switch shape {
                case let .dot(x, y, d): [.dot(x: x * (1 - u), y: y * (1 - u), d: lerp(d, base, u))]
                case let .oval(x, y, w, h): [.oval(x: x * (1 - u), y: y * (1 - u), w: lerp(w, base, u), h: lerp(h, base, u))]
                case let .ring(d, w): [.ring(d: lerp(d, base, u), w: lerp(w, 0.8, u))]
                case let .quill(outline, stem, rot, dx, dy): [.quill(outline: outline * (1 - u), stem: stem * (1 - u), rot: rot, dx: dx, dy: dy)] + (u > 0.6 ? [.dot(x: 0, y: 0, d: base * smooth((u - 0.6) / 0.4))] : [])
                }
            }
        }))
    }

    private func blend(_ shapes: [Shape], into loop: Segment, at time: CFTimeInterval) -> Segment? {
        let count = loop.track.frames.count, start = Int((time - loop.begin) * 60)
        var frames: [[Shape]] = []
        for index in 1...18 {
            let u = smooth(Double(index) / 18), to = loop.track.frames[(start + index) % count]
            guard to.count == shapes.count else { return nil }
            let mixed = zip(shapes, to).compactMap { from, to -> Shape? in
                switch (from, to) {
                case let (.dot(x, y, d), .dot(x2, y2, d2)): .dot(x: lerp(x, x2, u), y: lerp(y, y2, u), d: lerp(d, d2, u))
                case let (.oval(x, y, w, h), .oval(x2, y2, w2, h2)): .oval(x: lerp(x, x2, u), y: lerp(y, y2, u), w: lerp(w, w2, u), h: lerp(h, h2, u))
                case let (.ring(d, w), .ring(d2, w2)): .ring(d: lerp(d, d2, u), w: lerp(w, w2, u))
                case let (.quill(o, s, r, x, y), .quill(o2, s2, r2, x2, y2)): .quill(outline: lerp(o, o2, u), stem: lerp(s, s2, u), rot: lerp(r, r2, u), dx: lerp(x, x2, u), dy: lerp(y, y2, u))
                default: nil
                }
            }
            guard mixed.count == shapes.count else { return nil }
            frames.append(mixed)
        }
        return Segment(name: loop.name, loop: false, begin: time, track: Self.track(frames))
    }

    private func apply() {
        shown = segments.last.map { $0.begin + Double($0.track.frames.count) / 60 } ?? 0
        Self.carried[key] = (target, left, segments, shown)
        layer.removeAllAnimations()
        layer.path = segments.first?.track.paths.first ?? Self.path([.dot(x: 0, y: 0, d: base)])
        layer.fillColor = color(segments.first?.name)
        for (index, segment) in segments.enumerated() where segment.track.frames.count > 1 {
            let path = CAKeyframeAnimation(keyPath: "path"), fill = CABasicAnimation(keyPath: "fillColor"), group = CAAnimationGroup()
            path.values = segment.track.paths
            path.calculationMode = .discrete
            fill.fromValue = color(segment.name)
            fill.toValue = fill.fromValue
            group.animations = [path, fill]
            group.duration = Double(segment.track.frames.count) / 60
            path.duration = group.duration
            fill.duration = group.duration
            group.beginTime = segment.begin
            group.repeatCount = segment.loop ? .infinity : 1
            layer.add(group, forKey: "\(index)")
        }
    }

    private func color(_ name: String?) -> CGColor { selected ? .white : Self.ink(name) }
    static func ink(_ name: String?) -> CGColor { name == "blocked" ? amber : name == "background" ? grey : Spark.orange.cgColor }

    private static func track(_ name: String) -> (into: Track, loop: Track, out: Track) {
        if let cached = tracks[name] { return cached }
        let motion = motions.first { $0.name == name } ?? motions[0], outTime = motion.outTime ?? motion.inTime
        func sampled(_ time: Double, _ shapes: (Double) -> [Shape]) -> Track { track((0..<max(Int(time * 60), 1)).map { shapes(Double($0) / max(time * 60, 1)) }) }
        let made = (sampled(motion.inTime) { motion.pose($0) }, sampled(motion.loopTime) { motion.loop($0) }, sampled(outTime) { motion.out?($0) ?? motion.pose(1 - $0) })
        tracks[name] = made
        return made
    }

    static func image(_ name: String, at time: CFTimeInterval) -> NSImage {
        let paths = track(name).loop.paths, ink = paths[Int(time * 60) % paths.count], color = Self.ink(name)
        return NSImage(size: NSSize(width: 13, height: 13), flipped: false) { _ in
            let context = NSGraphicsContext.current!.cgContext
            context.addPath(ink)
            context.setFillColor(color)
            context.fillPath()
            return true
        }
    }

    private static func track(_ frames: [[Shape]]) -> Track { Track(frames: frames, paths: frames.map(path)) }

    private static func path(_ shapes: [Shape]) -> CGPath {
        let scale = 16.0 / 48, centre = 6.5
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: centre + x * scale, y: centre - y * scale) }
        func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGPath { CGPath(ellipseIn: CGRect(x: centre + (x - w / 2) * scale, y: centre - (y + h / 2) * scale, width: w * scale, height: h * scale), transform: nil) }
        return shapes.reduce(CGMutablePath() as CGPath) { ink, shape in
            switch shape {
            case let .dot(x, y, d): return ink.union(oval(x, y, d, d))
            case let .oval(x, y, w, h): return ink.union(oval(x, y, w, h))
            case let .ring(d, w): return ink.union(oval(0, 0, d - w, d - w).copy(strokingWithWidth: w * scale, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
            case let .quill(outline, stem, rot, dx, dy):
                let r = rot * .pi / 180, q = 4 * Double.pi / 180
                func place(_ p: (Double, Double)) -> CGPoint {
                    let x = (p.0 - 4.6) * cos(r) - (p.1 + 0.5) * sin(r) + 4.6 + dx, y = (p.0 - 4.6) * sin(r) + (p.1 + 0.5) * cos(r) - 0.5 + dy
                    return point(0.95 * (x * cos(q) - y * sin(q)), 0.95 * (x * sin(q) + y * cos(q)))
                }
                let lines = CGMutablePath()
                lines.addLines(between: part(featherOutline, 0, outline).map(place))
                if stem > 0 { lines.addLines(between: part(featherStem, 0.35 * (1 - stem), 0.35 + 0.65 * stem).map(place)) }
                return ink.union(lines.copy(strokingWithWidth: 3.6 * scale, lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
        }
    }
}


enum Clawd {
    struct Pose: Hashable { var lift = 0, dx = 0, eyes = "open", arms = "out", dim = 0.0, z: [[Double]] = [], spark: [[Int]] = [], frost: [Double] = [] }
    typealias Step = (seconds: Double, pose: Pose)
    static func asleep(z: [[Double]] = [], dim: Double = 1, eyes: String = "line") -> Pose { Pose(lift: -1, eyes: eyes, arms: "tucked", dim: dim, z: z) }
    private static let blink: [Step] = [(0.05, Pose(eyes: "squint")), (0.1, Pose(eyes: "line")), (0.05, Pose(eyes: "squint"))]
    private static let breath: [Step] = [(0.15, Pose(arms: "up")), (0.5, Pose(lift: 1)), (0.15, Pose(lift: 1, arms: "drop")), (0.1, Pose(arms: "drop"))]
    private static func rise(_ x: Double) -> [Step] { [[x, 0, 0.4], [x, -1, 0.9], [x + 1, -2, 1], [x + 1, -3, 0.45]].map { (0.25, asleep(z: [$0])) } }
    private static let idle: [Step] = [[(1, Pose())], breath, [(0.9, Pose())], blink, [(0.5, Pose())], breath, [(1.2, Pose())], breath, [(0.4, Pose())], blink, [(0.1, Pose())], blink, [(0.8, Pose())],
        [(0.6, Pose()), (0.1, Pose(dx: -1, eyes: "squint")), (1, Pose(dx: -1)), (0.5, Pose()), (0.1, Pose(dx: 1, eyes: "squint")), (1, Pose(dx: 1)), (0.4, Pose())], blink,
        [(0.5, Pose()), (0.15, Pose(arms: "up")), (0.15, Pose(lift: 1, eyes: "squint", arms: "up")), (0.8, Pose(lift: 1, eyes: "line", arms: "up")), (0.15, Pose(lift: 1, eyes: "squint")), (0.15, Pose(arms: "drop")), (0.8, Pose())]].joined().map { $0 }
    private static let fall: [Step] = [[(0.8, Pose())], blink, [(0.4, Pose()), (0.4, Pose(eyes: "squint")), (0.2, Pose()), (0.6, Pose(eyes: "squint")), (0.2, Pose(lift: -1, eyes: "line")), (0.1, Pose(eyes: "squint")),
        (0.5, Pose(eyes: "squint", arms: "drop")), (0.3, Pose(eyes: "line", arms: "drop")), (0.15, Pose(lift: -1, eyes: "line", arms: "drop"))], [0.2, 0.4, 0.6, 0.8, 1].map { (0.12, asleep(dim: $0)) }, rise(4), [(0.5, asleep())]].joined().map { $0 }
    private static let sleep: [Step] = [rise(4), [(0.3, asleep())], rise(9), [(0.3, asleep())]].joined().map { $0 }
    private static let wake: [Step] = [[(0.25, asleep(z: [[4, -1, 0.6]])), (0.25, asleep(z: [[5, -2, 0.3]]))], [0.75, 0.5, 0.25].map { (0.1, asleep(dim: $0, eyes: "squint")) },
        [(0.15, Pose(lift: -1, arms: "tucked")), (0.1, Pose(arms: "drop")), (0.1, Pose()), (0.1, Pose(lift: 1, arms: "drop", spark: [[14, 1, 0]])), (0.2, Pose(lift: 1, arms: "up", spark: [[14, 1, 1]])),
         (0.2, Pose(lift: 1, spark: [[14, 1, 2], [10, 0, 0]])), (0.1, Pose(arms: "drop", spark: [[14, 1, 1], [15, 3, 0]])), (0.2, Pose(spark: [[14, 1, 0]])), (1.4, Pose())]].joined().map { $0 }
    private static var images: [Pose: CGImage] = [:]
    static func frost(_ ink: String) -> [Double] { ink == "light" ? [25, 150, 195] : [125, 215, 240] }

    static func play(_ layer: CALayer, from: String?, to: String, since: CFTimeInterval, grow: Bool, seed: Double, frost: [Double]) {
        func frozen(_ steps: [Step]) -> [Step] {
            steps.map { step in
                var pose = step.pose
                pose.frost = frost
                if Spark.settings["sleep z"] == "off" { pose.z = [] }
                return (step.seconds, pose)
            }
        }
        layer.removeAllAnimations()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layer.contents = image(frozen([(0, to == "asleep" ? asleep(z: [[4, -1, 0.9]]) : Pose())])[0].pose)
            return
        }
        let loop = frozen(to == "asleep" ? sleep : idle), now = CACurrentMediaTime()
        let once = (from == "idle" && to == "asleep" ? fall : from == "asleep" && to != "asleep" ? wake : nil).map(frozen), end = since + (once ?? []).reduce(0) { $0 + $1.seconds }
        layer.contents = image(loop[0].pose)
        let repeating = keyframes(loop)
        repeating.repeatCount = .infinity
        if let once {
            let first = keyframes(once)
            first.beginTime = since
            layer.add(first, forKey: "once")
            repeating.beginTime = end
        } else {
            repeating.timeOffset = (now + seed).truncatingRemainder(dividingBy: repeating.duration)
        }
        layer.add(repeating, forKey: "loop")
        guard grow else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.3
        scale.toValue = 1
        scale.duration = 0.25
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "grow")
    }

    private static func keyframes(_ steps: [Step]) -> CAKeyframeAnimation { keyframes(steps.map { image($0.pose) }, steps.map(\.seconds)) }

    private static func keyframes(_ images: [CGImage], _ seconds: [Double]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contents"), total = seconds.reduce(0, +)
        animation.values = images
        animation.keyTimes = seconds.reduce(into: [0]) { times, step in times.append(times.last! + step) }.map { NSNumber(value: $0 / total) }
        animation.calculationMode = .discrete
        animation.duration = total
        return animation
    }

    static func image(_ pose: Pose) -> CGImage {
        if let cached = images[pose] { return cached }
        let context = CGContext(data: nil, width: 32, height: 34, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func fill(_ x: Int, _ y: Int, _ r: Double, _ g: Double, _ b: Double, _ alpha: Double = 1) {
            context.setFillColor(CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha))
            context.fill(CGRect(x: x * 2, y: (16 - y) * 2, width: 2, height: 2))
        }
        let dimmed = pose.frost.isEmpty ? [215.0, 119, 87].map { $0 - 0.38 * pose.dim * ($0 - 33) } : pose.frost, top = 7 - pose.lift
        func body(_ x: Int, _ y: Int) { fill(x, y, dimmed[0], dimmed[1], dimmed[2]) }
        for y in top..<top + 8 { for x in 2..<14 { body(x, y) } }
        for x in [3, 5, 10, 12] { for y in top + 8..<17 { body(x, y) } }
        if pose.arms != "tucked" {
            let row = top + 5 + (pose.arms == "up" ? -1 : pose.arms == "drop" ? 1 : 0)
            for y in [row, row + 1] { for x in [0, 1, 14, 15] { body(x, y) } }
        }
        for (index, x) in [4 + pose.dx, 11 + pose.dx].enumerated() {
            switch pose.eyes {
            case "open": for y in [top + 2, top + 3] { fill(x, y, 20, 20, 20) }
            case "squint": fill(x, top + 3, 20, 20, 20)
            default: for i in index == 0 ? [x - 1, x] : [x, x + 1] { fill(i, top + 3, 20, 20, 20) }
            }
        }
        for z in pose.z {
            for (i, j) in (0..<5).map({ ($0, 0) }) + [(3, 1), (2, 2), (1, 3)] + (0..<5).map({ ($0, 4) }) { fill(Int(z[0]) + i, 3 + Int(z[1]) + j, 150, 150, 155, z[2]) }
        }
        for spark in pose.spark {
            let reach = [(0, 0)] + (spark[2] > 0 ? [(1, 0), (-1, 0), (0, 1), (0, -1)] : []) + (spark[2] > 1 ? [(2, 0), (-2, 0), (0, 2), (0, -2)] : [])
            for (i, j) in reach where (0..<16).contains(spark[0] + i) { fill(spark[0] + i, 3 + spark[1] + j, 0, 144, 255) }
        }
        let made = context.makeImage()!
        images[pose] = made
        return made
    }
}


extension Marks {
    static func rest(_ layer: CALayer, asleep: Bool, color: CGColor, fade: Float, phase: Int) {
        layer.removeAllAnimations()
        layer.contents = nil
        layer.opacity = asleep ? fade : 1
        let moving = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 6.5 + x / 2, y: 6.75 - y / 2) }
        func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGPath { CGPath(ellipseIn: CGRect(origin: at(x - w / 2, y + h / 2), size: CGSize(width: w / 2, height: h / 2)), transform: nil) }
        func shape(_ path: CGPath, opacity: Float = 1, line: Double = 0) -> CAShapeLayer {
            let shape = CAShapeLayer()
            shape.path = path
            shape.opacity = opacity
            shape.fillColor = line > 0 ? nil : color
            shape.strokeColor = line > 0 ? color : nil
            shape.lineWidth = line / 2
            shape.lineJoin = .round
            shape.lineCap = .round
            return shape
        }
        func loop(_ shape: CALayer, _ animations: [CAAnimation], seconds: Double, back: Bool = false, offset: Double = 0) {
            guard moving else { return }
            let group = CAAnimationGroup()
            group.animations = animations
            group.duration = seconds
            group.autoreverses = back
            group.repeatCount = .infinity
            group.beginTime = CACurrentMediaTime()
            group.timeOffset = group.beginTime + offset + Double(phase) * 0.7
            for animation in animations { animation.duration = seconds }
            shape.add(group, forKey: "rest")
        }
        func change(_ key: String, _ from: Any, _ to: Any, curve: CAMediaTimingFunction? = nil) -> CABasicAnimation {
            let change = CABasicAnimation(keyPath: key)
            change.fromValue = from
            change.toValue = to
            change.timingFunction = curve
            return change
        }
        let sine = CAMediaTimingFunction(controlPoints: 0.37, 0, 0.63, 1)
        func keyed(_ key: String, _ keys: [(Double, Any)], seconds: Double, eased: Bool = true) -> CAKeyframeAnimation {
            let animation = CAKeyframeAnimation(keyPath: key)
            animation.values = keys.map(\.1)
            animation.keyTimes = keys.map { NSNumber(value: $0.0 / seconds) }
            if eased { animation.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: keys.count - 1) }
            return animation
        }
        guard asleep else {
            func rays(_ t: Double) -> CGPath {
                let path = CGMutablePath(), turn = 4 * sin(2 * .pi * t)
                for i in 0..<8 {
                    let angle = (Double(i) * 45 + turn) * .pi / 180, length = (i % 2 == 0 ? 10 : 7.4) + 0.9 * sin(2 * .pi * (t - Double(i) / 8))
                    path.addLines(between: [at(1.6 * cos(angle), 1.6 * sin(angle)), at(length * cos(angle), length * sin(angle))])
                }
                return path
            }
            let star = shape(rays(0), line: 2.6), steps = (0...60).map { Double($0) / 60 }
            loop(star, [keyed("path", steps.map { ($0 * 5, rays($0)) }, seconds: 5, eased: false)], seconds: 5)
            layer.sublayers = [star]
            return
        }
        func crescent(_ degrees: Double) -> CGPath {
            let center = at(-2, 2), cut = oval(-2, 2, 18, 18).subtracting(oval(2.5, -1.5, 15, 15))
            var turn = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: degrees * .pi / 180).translatedBy(x: -center.x, y: -center.y)
            return cut.copy(using: &turn)!
        }
        let moon = shape(crescent(4))
        loop(moon, [change("path", crescent(4), crescent(-4), curve: sine)], seconds: 2.2, back: true)
        func z(_ u: Double, _ start: (x: Double, y: Double, drift: Double)) -> CGPath {
            let x = start.x + start.drift * u * u * (3 - 2 * u) + 0.8 * sin(2 * .pi * u), y = start.y - 9 * u, half = (5.5 + 2 * u) / 2, path = CGMutablePath()
            path.addLines(between: [at(x - half, y - half), at(x + half, y - half), at(x - half, y + half), at(x + half, y + half)])
            return path
        }
        let steps = (0...12).map { Double($0) / 12 }
        let starts = [(9.0, -6.0, 0.0), (18, -7, 1), (8, -9, 0), (19, -5, 1)], cycle = 1.5 * Double(starts.count)
        let zs = starts.enumerated().map { index, start in
            let mark = shape(z(moving ? 0 : 0.4, start), opacity: moving ? 0 : 1, line: 1.8)
            let rise = keyed("path", steps.map { ($0 * 3, z($0, start)) } + [(cycle, z(1, start))], seconds: cycle, eased: false)
            let fade = keyed("opacity", steps.map { ($0 * 3, min(1, 1.2 * min(1, $0 * 5) * pow(1 - $0, 0.6))) } + [(cycle, 0.0)], seconds: cycle, eased: false)
            loop(mark, [rise, fade], seconds: cycle, offset: cycle - Double(index) * 1.5)
            return mark
        }
        layer.sublayers = [moon] + (Spark.settings["sleep z"] == "off" ? [] : moving ? zs : [zs[0]])
    }
}


private typealias Field = (Double, Double) -> Double
private struct Prop { let field: Field, ink: String, alpha: Double }
private struct Stance { var lift = 0, dx = 0, ey = 0, eyes = "open", arms = ("out", "out") }
private func prop(_ field: @escaping Field, _ ink: String = "label", _ alpha: Double = 1) -> Prop { Prop(field: field, ink: ink, alpha: alpha) }
private func disc(_ cx: Double, _ cy: Double, _ r: Double) -> Field { { x, y in hypot(x - cx, y - cy) - r } }
private func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ r: Double = 0) -> Field {
    let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, hx = (x1 - x0) / 2 - r, hy = (y1 - y0) / 2 - r
    return { x, y in
        let qx = abs(x - cx) - hx, qy = abs(y - cy) - hy
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
    }
}
private func seg(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ w: Double, _ w2: Double? = nil) -> Field {
    let dx = bx - ax, dy = by - ay, length = dx * dx + dy * dy, w2 = w2 ?? w
    return { x, y in
        let t = clamp(((x - ax) * dx + (y - ay) * dy) / (length == 0 ? 1 : length))
        return hypot(x - ax - t * dx, y - ay - t * dy) - (w + (w2 - w) * t) / 2
    }
}
private func poly(_ points: [(Double, Double)]) -> Field {
    { x, y in
        var distance = 1e9, sign = 1.0
        for (index, (ax, ay)) in points.enumerated() {
            let (bx, by) = points[(index + points.count - 1) % points.count], ex = bx - ax, ey = by - ay, wx = x - ax, wy = y - ay
            let t = clamp((wx * ex + wy * ey) / (ex * ex + ey * ey))
            distance = min(distance, hypot(wx - ex * t, wy - ey * t))
            if (ay <= y && y < by || by <= y && y < ay) && x < ax + (y - ay) * ex / ey { sign = -sign }
        }
        return sign * distance
    }
}
private func curve(_ a: (Double, Double), _ c: (Double, Double), _ b: (Double, Double), _ w: Double, _ w2: Double? = nil) -> Field {
    let points = (0...12).map { i -> (Double, Double) in
        let t = Double(i) / 12, ka = (1 - t) * (1 - t), kc = 2 * (1 - t) * t, kb = t * t
        return (ka * a.0 + kc * c.0 + kb * b.0, ka * a.1 + kc * c.1 + kb * b.1)
    }, w2 = w2 ?? w, step = (w2 - w) / 12
    return union((0..<12).map { i -> Field in seg(points[i].0, points[i].1, points[i + 1].0, points[i + 1].1, w + step * Double(i), w + step * Double(i + 1)) })
}
private func union(_ fields: [Field]) -> Field { { x, y in fields.reduce(.infinity) { min($0, $1(x, y)) } } }
private func inter(_ a: @escaping Field, _ b: @escaping Field) -> Field { { x, y in max(a(x, y), b(x, y)) } }
private func stroke(_ f: @escaping Field, _ w: Double = 1.2) -> Field { { x, y in abs(f(x, y)) - w / 2 } }
private func moved(_ f: @escaping Field, _ dy: Double) -> Field { { x, y in f(x, y - dy) } }
private func scaled(_ f: @escaping Field, _ k: Double, _ cx: Double, _ cy: Double) -> Field { { x, y in f(cx + (x - cx) / k, cy + (y - cy) / k) * k } }
private func squashed(_ props: [Prop], _ k: Double) -> [Prop] { props.map { p in prop({ x, y in p.field(x, 8.7 + (y - 8.7) / k) * k }, p.ink, p.alpha) } }
private func star(_ cx: Double, _ cy: Double, _ n: Int, _ r: Double, _ w: Double, _ w2: Double? = nil, rot: Double = -90, core: Double = 0) -> Field {
    let arms = (0..<n).map { k in
        let a = (rot + 360 * Double(k) / Double(n)) * .pi / 180
        return seg(cx, cy, cx + r * cos(a), cy + r * sin(a), w, w2)
    }
    return union(core > 0 ? arms + [disc(cx, cy, core)] : arms)
}
private func near(_ v: Double) -> Int { Int(v.rounded(.toNearestOrEven)) }

extension Clawd {
    private typealias Act = (seconds: Double, body: Stance, props: [Prop])

    private static let acts: [String: [Act]] = {
        var acts: [String: [Act]] = [:]
        let up = Stance(dx: 1, ey: -2)
        let t1 = disc(11.2, 13.0, 0.85), t2 = disc(13.3, 11.6, 1.15)
        let cloud = stroke(union([disc(15.8, 7.8, 2.6), disc(20.2, 7.5, 2.9), disc(24.8, 7.5, 2.9), disc(28.6, 8.2, 2.2), box(15, 8, 29.5, 10.4, 1)]))
        let dots = [18.6, 22.5, 26.4].map { disc($0, 8.0, 1.1) }
        let ponder: [Act] = (0..<4).map { k in
            let lit: [Prop] = dots.enumerated().map { prop($1, "label", $0 < k ? 1 : 0.35) }
            return (0.3, k == 2 ? Stance(dx: 1, eyes: "line") : up, [prop(t1), prop(t2), prop(cloud)] + lit)
        }
        let fade: [Prop] = ([t1, t2, cloud] + dots).map { prop($0, "label", 0.4) }
        acts["think"] = [(0.35, up, []), (0.25, up, [prop(t1)]), (0.25, up, [prop(t1), prop(t2)])] + ponder + [(0.3, up, fade), (0.3, Stance(), [])]
        let bubble = stroke(union([box(5, 4.6, 27, 11.4, 3), poly([(8.6, 10), (12.6, 10), (8.4, 13.5)])]))
        let talk = Stance(ey: -2), wave: [Act] = (0..<4).map { k in
            (0.16, talk, [prop(bubble)] + [(11.0, 8.0), (16, 8), (21, 8)].enumerated().map { i, at in prop(disc(at.0, at.1 - (i == k ? 1 : 0), 1.1), "label", i == k ? 1 : 0.45) })
        }
        acts["compose"] = [(0.12, talk, [prop(disc(8.4, 12.6, 1))])] + [0.45, 0.75].map { (0.1, talk, [prop(scaled(bubble, $0, 8.4, 13.5))]) } + wave + wave + wave + wave
        let glyph = [disc(16, 12, 1.1), star(16, 10.6, 4, 2.3, 1.3, core: 0.9), star(16, 9.6, 8, 3.1, 1.2, core: 0.8), star(16, 9.0, 6, 3.6, 1.0, 1.9, core: 1.1),
                     star(16, 8.7, 8, 3.6, 0.9, 1.8, core: 1.0), star(16, 8.7, 8, 3.5, 1.2, 2.2, rot: -67.5, core: 1.4)]
        acts["default"] = [0, 1, 2, 3, 4, 5, 5, 4, 3, 2, 1, 0].enumerated().map { i, g in (g == 0 ? 0.3 : 0.13, Stance(lift: [1, 2].contains(i % 4) ? 1 : 0, ey: -1), [prop(glyph[g])]) }
        let page = prop(stroke(box(9.6, 4.6, 22.4, 12.8, 1.4))), lines = [(6.9, 19.6), (8.8, 19.6), (10.7, 17.2)], read = lines.map { prop(seg(12.2, $0, $1, $0, 1.0)) }
        let faint: [Prop] = lines.map { prop(seg(12.2, $0, $1, $0, 1.0), "label", 0.32) }
        let reading: [Act] = lines.indices.flatMap { li in
            [0.34, 0.67, 1.0].map { (part: Double) -> Act in
                let done: [Prop] = lines[...li].enumerated().map { lj, line in prop(seg(12.2, line.0, 12.2 + (line.1 - 12.2) * (lj == li ? part : 1), line.0, 1.0)) }
                return (0.2, Stance(dx: near(part * 2 - 1), ey: -2), [page] + faint + done)
            }
        }
        acts["read"] = reading + [(0.4, Stance(ey: -2), [page] + read), (0.1, Stance(eyes: "line"), [page] + read)]
        acts["search"] = [7, 10, 13, 16, 19, 22, 24.5, 22, 19, 16, 13, 10].enumerated().map { i, cx in
            (0.13, Stance(dx: max(-2, min(2, near((cx - 16) / 4))), ey: -2), [prop(union([stroke(disc(cx, 7.9, 3.0), 1.3), seg(cx + 2.3, 10.2, cx + 4.3, 12.2, 1.9)]))]
                + ([2, 3].contains(i % 6) ? [prop(seg(cx - 1.7, 7.4, cx - 0.6, 6.0, 0.8), "label", 0.75)] : []))
        }
        func waveY(_ x: Double) -> Double { 10.6 + 1.6 * sin((x - 5) * 0.62) }
        func scribble(_ end: Double) -> [Prop] {
            let xs = (0...Int((end - 5) * 2)).map { 5 + 0.5 * Double($0) }
            return zip(xs, xs.dropFirst()).map { prop(seg($0, waveY($0), $1, waveY($1), 1.15)) }
        }
        func pencil(_ tx: Double) -> Prop {
            let ty = waveY(tx)
            return prop(union([seg(tx + 1.1, ty - 1.1, tx + 3.4, ty - 3.4, 2.2), seg(tx, ty, tx + 1.3, ty - 1.3, 0.6, 1.8)]))
        }
        let writing: [Act] = [5.0, 8, 11, 14, 17, 20, 23].enumerated().map { i, x -> Act in
            (0.2, Stance(dx: near((x - 15) / 6), ey: -1, arms: i % 2 == 1 ? ("up", "drop") : ("drop", "up")), scribble(x) + [pencil(x)])
        }
        acts["write"] = writing + [(0.45, Stance(dx: 1, ey: -1), scribble(23) + [pencil(23)]), (0.25, Stance(), [])]
        let term: [Prop] = [prop(stroke(box(6.6, 4.6, 25.4, 13.0, 1.8))), prop(union([seg(9.2, 6.9, 11.1, 8.7, 1.25), seg(11.1, 8.7, 9.2, 10.5, 1.25)]))]
        let chars: [Prop] = (0..<4).map { i in prop(box(13.2 + Double(i) * 2.5, 7.4, 14.5 + Double(i) * 2.5, 10.4, 0.3)) }
        func cursor(_ i: Int) -> Prop { prop(box(13.0 + Double(i) * 2.5, 9.9, 14.8 + Double(i) * 2.5, 10.8)) }
        let typing: [Act] = (0..<5).map { n -> Act in (0.14, Stance(ey: -1, arms: n % 2 == 1 ? ("up", "drop") : ("drop", "up")), term + chars[..<n] + [cursor(n)]) }
        let blinking: [Act] = (0..<4).map { k -> Act in (0.3, Stance(ey: -1), term + chars + (k % 2 == 1 ? [cursor(4)] : [])) }
        acts["code"] = typing + blinking + [(0.2, Stance(ey: -1), term)]
        let screen = prop(stroke(box(9.6, 4.6, 22.4, 12.8, 1.6)), "grey")
        let looks = [Stance(ey: -2), Stance(ey: -2), Stance(dx: 1, ey: -2), Stance(eyes: "line"), Stance(ey: -2), Stance(ey: -2), Stance(dx: -1), Stance(dx: -1)]
        acts["background A"] = (0..<32).map { i in
            let a = [90.0, 135, 0, 45][i % 4] * .pi / 180
            return (0.15, looks[(i / 4) % 8], [screen, prop(seg(16 - 2.2 * cos(a), 8.7 - 2.2 * sin(a), 16 + 2.2 * cos(a), 8.7 + 2.2 * sin(a), 1.2), "grey")])
        }
        let topSand = poly([(12, 4.6), (20, 4.6), (16, 8.7)]), bottomSand = poly([(16, 8.7), (20, 12.8), (12, 12.8)])
        let glass = prop(union([stroke(union([topSand, bottomSand]), 1.1), seg(11.2, 4.6, 20.8, 4.6, 1.2), seg(11.2, 12.8, 20.8, 12.8, 1.2)]), "grey")
        func sand(_ f: Double) -> [Prop] {
            let left = sqrt(max(0, 1 - f))
            var props = [glass]
            if 1 - f > 0.02 { props.append(prop(inter(topSand) { _, y in y - (8.7 - 4.1 * left) }, "grey", 0.8)) }
            if f > 0.02 { props.append(prop(inter(bottomSand) { _, y in y - (12.8 - 4.1 * (1 - left)) }, "grey", 0.8)) }
            if 0 < f && f < 1 { props.append(prop(seg(16, 8.7, 16, 12.4, 0.6), "grey", 0.8)) }
            return props
        }
        let stand = Stance(ey: -2), turn = Stance(dx: 1, ey: -2)
        let pouring: [Act] = [0, 0.2, 0.4, 0.6, 0.8, 1.0].enumerated().map { i, f -> Act in (0.35, i == 3 ? Stance(eyes: "line") : stand, sand(f)) }
        acts["background B"] = pouring + [(0.3, stand, sand(1)), (0.1, turn, squashed(sand(1), 0.45)), (0.1, turn, squashed(sand(0), 0.45)), (0.3, stand, sand(0))]
        func fishing(_ angle: Double, _ bob: (Double, Double), bend: Double = 1.2, slack: Double = 0, ripple: (Double, Double)? = nil) -> [Prop] {
            let a = angle * .pi / 180, reach = min(29, 27.2 / max(0.01, -sin(a))), tip = (30 + reach * cos(a), 28 + reach * sin(a)), down = cos(a) < 0 ? -1.0 : 1.0
            let rod = curve((30, 28), (15 + tip.0 / 2 - down * sin(a) * bend, 14 + tip.1 / 2 + down * cos(a) * bend), tip, 1.4, 0.8)
            let line = curve(tip, ((tip.0 + bob.0) / 2, (tip.1 + bob.1) / 2 + slack), (bob.0, bob.1 - 1.1), 0.6)
            let rings: [Prop] = ripple.map { (k: Double, alpha: Double) -> [Prop] in [-1.0, 1].map { (s: Double) -> Prop in prop(seg(bob.0 + s * (1.6 + k), 31.5, bob.0 + s * (2.6 + k), 31.5, 0.7), "grey", alpha) } } ?? []
            return [prop(seg(0, 32.4, 6.5, 32.4, 0.9), "grey", 0.6), prop(rod), prop(line, "grey", 0.8)] + rings + [prop(disc(bob.0, bob.1, 1.3), "grey")]
        }
        let fish = Stance(dx: -1, ey: -1, arms: ("tucked", "drop")), reel = Stance(dx: -1, ey: -2, arms: ("tucked", "drop")), look = Stance(dx: -2, ey: -2, arms: ("tucked", "drop")), wince = Stance(dx: -1, eyes: "line", arms: ("tucked", "drop"))
        let rest = 193.0, float = (2.6, 30.4)
        let waiting: [Act] = (0..<4).map { k in (0.35, k == 2 ? wince : fish, fishing(rest, (2.6, 30.4 + Double(k % 2) * 0.5))) }
        let nibble: [Act] = [(0.12, look, fishing(rest, (2.6, 31.8), bend: 2.4, ripple: (0, 0.7))), (0.25, look, fishing(rest, float, ripple: (1, 0.4))),
                             (0.12, look, fishing(rest, (2.6, 32), bend: 2.8, ripple: (0, 0.7))), (0.3, look, fishing(rest, float, ripple: (1, 0.4)))]
        let recast: [Act] = [(0.1, reel, fishing(209, (3.6, 27.4), bend: -0.5)), (0.12, reel, fishing(225, (7.6, 20), bend: -0.5, slack: 0.5)), (0.2, wince, fishing(225, (11.6, 13), bend: 0, slack: 1)),
                             (0.16, reel, fishing(255, (8.6, 9), bend: -1, slack: 1.5)), (0.08, reel, fishing(224, (5.6, 4), bend: 2.5)), (0.08, fish, fishing(rest, (4.1, 9), slack: 1.5)),
                             (0.08, fish, fishing(rest, (3, 20), slack: 1.5)), (0.08, fish, fishing(rest, (2.6, 31.6))), (0.15, fish, fishing(rest, float, ripple: (0, 0.8))),
                             (0.2, fish, fishing(rest, float, ripple: (1.2, 0.45))), (0.25, fish, fishing(rest, float, ripple: (2.2, 0.2)))]
        acts["background C"] = waiting + nibble + recast
        let bang = union([box(28.2, 7.8, 31.0, 16.2, 1.2), disc(29.6, 19.6, 1.5)])
        let waving: [Act] = (0..<4).map { k -> Act in (0.2, Stance(arms: (k % 2 == 0 ? "high" : "lift", "drop")), [prop(moved(bang, k % 2 == 0 ? -1.2 : 0), "amber")]) }
        acts["blocked"] = waving + [(0.6, Stance(arms: ("out", "drop")), [prop(bang, "amber")])]
        return acts
    }()
    private static var drawn: [String: (images: [CGImage], seconds: [Double], still: Int)] = [:]

    static func act(_ layer: CALayer, _ name: String, ink: String, since: CFTimeInterval) -> Double {
        layer.removeAllAnimations()
        let key = name + " " + ink, (images, seconds, still) = drawn[key] ?? {
            let script = acts[name] ?? acts["default"]!, made = (script.map { draw($0, ink: ink) }, script.map(\.seconds), script.indices.max { script[$0].props.count < script[$1].props.count }!)
            drawn[key] = made
            return made
        }()
        layer.contents = images[NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? still : 0]
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return 0 }
        let loop = keyframes(images, seconds)
        loop.repeatCount = Float.infinity
        loop.beginTime = CACurrentMediaTime()
        loop.timeOffset = (loop.beginTime - since).truncatingRemainder(dividingBy: loop.duration)
        layer.add(loop, forKey: "loop")
        return loop.duration - loop.timeOffset
    }

    private static func draw(_ act: Act, ink: String) -> CGImage {
        var cells = [UInt8](repeating: 0, count: 32 * 34)
        let body = act.body, top = 14 - body.lift
        func cell(_ x: Int, _ y: Int, _ kind: UInt8) { if (0..<32).contains(x), (0..<34).contains(y) { cells[y * 32 + x] = kind } }
        for y in top..<top + 16 { for x in 4..<28 { cell(x, y, 1) } }
        for x in [6, 10, 20, 24] { for y in top + 16..<34 { cell(x, y, 1); cell(x + 1, y, 1) } }
        for (arm, xs) in [(body.arms.0, 0..<4), (body.arms.1, 28..<32)] where arm != "tucked" {
            let shift = ["up": -2, "drop": 2, "lift": -4][arm] ?? 0, ys = arm == "high" ? top - 6..<top + 4 : top + 10 + shift..<top + 14 + shift
            for y in ys { for x in xs { cell(x, y, 1) } }
        }
        for (index, x) in [8 + body.dx, 22 + body.dx].enumerated() {
            let (xs, ys) = switch body.eyes {
            case "open": ([x, x + 1], Array(top + 4 + body.ey..<top + 8 + body.ey))
            case "squint": ([x, x + 1], [top + 6, top + 7])
            default: (index == 0 ? Array(x - 2...x + 1) : Array(x...x + 3), [top + 6, top + 7])
            }
            for y in ys { for x in xs { cell(x, y, 2) } }
        }
        var cover = [(ink: [Double], alpha: Double)?](repeating: nil, count: 32 * 34)
        for p in act.props {
            let color: [Double] = ink == "selected" ? [255.0, 255, 255] : p.ink == "grey" ? [138, 138, 144] : p.ink == "amber" ? [242, 180, 78] : ink == "dark" ? [255, 255, 255] : [24, 24, 26]
            for y in 0..<34 {
                for x in 0..<32 where p.field(Double(x) + 0.5, Double(y) + 0.5) <= 1.2 {
                    let hits = (0..<9).filter { p.field(Double(x) + (Double($0 % 3) + 0.5) / 3, Double(y) + (Double($0 / 3) + 0.5) / 3) <= 0 }.count
                    if hits > 0 { cover[y * 32 + x] = (color, Double(hits) / 9 * p.alpha) }
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: 32 * 34 * 4)
        for index in 0..<32 * 34 {
            let under: [Double]? = cells[index] == 1 ? [215, 119, 87] : cells[index] == 2 ? [20, 20, 20] : nil
            let pixel: [Double] = switch (under, cover[index]) {
            case let (under?, ink?): under.indices.map { Double(Int(under[$0] + (ink.ink[$0] - under[$0]) * ink.alpha)) } + [255]
            case let (under?, nil): under + [255]
            case let (nil, ink?): ink.ink.map { ($0 * ink.alpha).rounded() } + [(255 * ink.alpha).rounded()]
            case (nil, nil): [0, 0, 0, 0]
            }
            for channel in 0..<4 { bytes[index * 4 + channel] = UInt8(pixel[channel]) }
        }
        let context = CGContext(data: &bytes, width: 32, height: 34, bitsPerComponent: 8, bytesPerRow: 32 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }
}


private let thinkKeys: [Phase] = [Phase(frames: 16, dots: [
        [[0, -0.2, 0.0, 3.6], [1, 2.1, -0.0, 4.4], [3, 6.8, 0.1, 7.3], [5, 10.2, 0.1, 8.7], [7, 12.9, 0.1, 9.1], [10, 15.1, 0.1, 8.7], [15, 16.5, 0.1, 8.2]],
        [[0, -0.2, 0.1, 3.6], [1, -0.0, 0.9, 2.5], [2, 0.6, 0.2, 5.0], [3, 1.9, 0.3, 5.8], [5, 3.7, 0.2, 6.1], [6, 3.7, 0.3, 6.0], [14, -0.1, 0.2, 5.5], [15, -1.2, 0.3, 5.8]],
        [[0, -0.2, 0.1, 3.6], [2, -3.8, 0.1, 4.7], [5, -11.3, 0.1, 6.2], [7, -14.7, 0.1, 7.1], [10, -16.4, 0.1, 8.0], [15, -16.0, 0.1, 8.5]]]),
    Phase(frames: 110, dots: [
        [[0, 16.7, 0.1, 8.0], [5, 16.5, 0.1, 7.5], [8, 15.0, -0.1, 7.0], [11, 12.4, -0.7, 6.3], [16, 5.7, -3.3, 5.9], [21, -3.0, -6.8, 6.0], [23, -6.7, -7.3, 6.2], [24, -8.4, -6.7, 6.3], [28, -14.0, -2.2, 6.7], [30, -16.0, -0.4, 7.1], [32, -17.0, 0.9, 7.7], [35, -15.9, 1.7, 8.6], [37, -13.1, 1.6, 9.0], [39, -8.9, 1.2, 9.5], [45, 6.4, 0.3, 9.7], [48, 11.7, 0.1, 9.1], [50, 13.9, 0.1, 8.9], [54, 16.4, 0.1, 8.2], [58, 16.9, 0.1, 8.0], [61, 16.4, 0.1, 7.5], [63, 15.5, 0.1, 7.1], [66, 13.1, 0.7, 6.5], [71, 6.0, 2.8, 5.9], [76, -3.5, 5.5, 5.9], [78, -7.5, 5.7, 6.2], [82, -14.1, 2.1, 6.7], [84, -16.2, 0.3, 7.1], [86, -17.0, -0.9, 7.8], [88, -16.2, -1.5, 8.4], [90, -13.6, -1.6, 9.0], [92, -9.4, -1.4, 9.4], [97, 3.9, -0.0, 9.7], [99, 8.1, 0.1, 9.4], [101, 11.4, 0.1, 9.2], [104, 14.4, 0.1, 8.8], [109, 16.2, 0.1, 8.2]],
        [[0, -1.8, 0.3, 5.7], [7, -7.7, -0.2, 6.1], [13, -14.6, -0.5, 6.7], [16, -16.8, 0.8, 7.6], [19, -16.4, 4.0, 8.3], [21, -14.2, 7.2, 8.6], [23, -10.5, 10.6, 8.8], [24, -8.2, 11.6, 9.0], [25, -5.7, 11.7, 9.1], [27, 0.1, 10.6, 9.2], [31, 11.1, 5.3, 9.1], [33, 14.6, 3.1, 8.8], [36, 16.6, 1.0, 7.9], [38, 16.1, 0.4, 7.3], [40, 14.7, 0.2, 6.9], [43, 11.6, 0.3, 6.1], [49, 4.5, 0.4, 5.9], [53, 1.0, 0.3, 5.8], [54, -0.8, 0.3, 5.8], [57, -2.4, 0.3, 5.7], [60, -5.1, 0.5, 5.8], [62, -7.5, 0.6, 6.5], [63, -7.5, 0.6, 7.0], [65, -10.7, 1.0, 6.3], [68, -14.2, 1.0, 6.6], [70, -16.0, 0.6, 7.1], [72, -17.0, -0.5, 7.8], [74, -16.5, -2.5, 8.2], [75, -15.5, -3.9, 8.5], [77, -11.9, -6.9, 8.9], [79, -6.7, -9.2, 9.3], [81, -0.3, -8.5, 9.4], [83, 6.4, -6.3, 9.4], [85, 11.8, -3.9, 9.1], [87, 15.1, -1.8, 8.6], [89, 16.5, -0.5, 8.0], [91, 16.2, 0.2, 7.4], [93, 14.9, 0.5, 6.9], [96, 11.7, 0.5, 6.2], [99, 7.7, 0.4, 6.8], [100, 7.6, 0.4, 6.7], [102, 4.8, 0.4, 5.9], [109, -0.5, 0.3, 5.7]],
        [[0, -15.7, 0.1, 8.6], [4, -13.0, 0.2, 9.1], [7, -8.7, 1.0, 9.6], [10, -2.5, 2.1, 9.6], [15, 9.6, 4.7, 9.3], [17, 13.4, 5.1, 8.9], [19, 15.8, 4.5, 8.4], [22, 16.6, 1.7, 7.6], [25, 14.9, -2.1, 6.8], [27, 12.6, -3.4, 6.5], [29, 9.5, -3.8, 6.2], [35, -1.3, -1.7, 5.7], [39, -8.2, -0.5, 6.2], [44, -14.4, 0.2, 6.7], [46, -15.9, 0.1, 7.1], [49, -17.0, 0.1, 7.7], [53, -16.9, 0.1, 8.2], [56, -15.7, 0.1, 8.6], [59, -13.9, -0.0, 9.0], [62, -10.2, -0.5, 9.3], [65, -4.1, -1.5, 9.7], [70, 9.0, -3.5, 9.5], [72, 13.3, -3.8, 8.9], [74, 15.9, -3.1, 8.4], [76, 16.7, -1.7, 7.7], [79, 15.1, 1.7, 7.0], [81, 12.5, 3.2, 6.4], [83, 9.2, 3.6, 6.0], [90, -4.3, 1.6, 5.6], [92, -7.8, 0.9, 6.2], [95, -12.1, 0.3, 6.3], [97, -14.3, 0.2, 6.7], [99, -15.8, 0.2, 7.0], [102, -16.9, 0.1, 7.6], [106, -17.0, 0.1, 8.1], [109, -16.2, 0.1, 8.4]]]),
    Phase(frames: 15, dots: [
        [[0, 16.1, -0.0, 8.0], [2, 15.3, -0.3, 7.7], [4, 13.2, -0.3, 6.9], [6, 9.9, 0.2, 6.2], [10, 2.4, 1.4, 7.3], [11, 1.3, 1.2, 6.8], [12, 0.1, -0.0, 6.5], [14, -0.1, 0.1, 3.5]],
        [[0, -1.0, 0.5, 5.7], [5, -4.8, 2.4, 5.3], [7, -5.0, 2.7, 6.0], [9, -3.5, 1.7, 7.2], [11, -0.7, 0.4, 8.2], [12, 0.2, 0.4, 6.6], [14, 0.2, 0.3, 2.8]],
        [[0, -15.7, -0.0, 8.3], [2, -13.6, -0.8, 8.3], [3, -11.8, -1.4, 8.1], [6, -4.8, -3.8, 7.3], [8, -1.0, -4.0, 7.3], [10, 0.4, -2.1, 7.7], [12, -0.0, 0.2, 6.8], [14, 0.1, -0.1, 3.2]]])]
private let searchKeys: [Phase] = [Phase(frames: 16, dots: [
        [[0, -0.0, 0.0, 5.3], [3, -1.5, 0.2, 5.2], [4, -2.7, 0.2, 5.0], [5, -3.7, 0.1, 5.8], [9, -11.0, 0.2, 7.6], [11, -13.9, 0.1, 8.1], [13, -15.4, 0.1, 8.3], [15, -15.9, 0.2, 8.3]],
        [[0, -0.1, 0.1, 5.5], [2, 0.4, 0.1, 5.5], [4, 1.9, 0.1, 5.9], [5, 3.0, 0.0, 6.4], [6, 5.0, 0.1, 6.2], [9, 10.8, 0.1, 7.5], [11, 13.7, 0.1, 8.1], [13, 15.2, 0.1, 8.2], [15, 15.7, 0.1, 8.3]],
        [[0, -0.1, -0.2, 5.1], [1, -0.2, -0.2, 4.8], [2, -0.4, -0.2, 5.4], [5, -2.1, 0.1, 5.5], [6, 0.0, 0.0, 5.0], [11, -0.1, 0.1, 4.1], [15, -0.1, 0.1, 4.2]]]),
    Phase(frames: 20, dots: [
        [[0, -15.8, 0.1, 8.3], [2, -14.7, 0.2, 8.3], [4, -12.4, 0.1, 8.4], [5, -10.6, 0.1, 8.4], [7, -5.7, 0.1, 8.3], [11, 6.0, 0.1, 8.4], [14, 12.3, 0.1, 8.3], [16, 14.5, 0.1, 8.4], [19, 15.6, 0.1, 8.4]],
        [[0, 15.6, 0.1, 8.3], [3, 14.6, 0.2, 8.0], [5, 13.0, 0.1, 7.8], [10, 5.8, 0.1, 6.2], [11, 4.8, 0.1, 6.1], [13, 2.4, 0.0, 4.7], [16, 0.5, 0.1, 4.1], [19, -0.0, 0.1, 4.0]],
        [[0, -0.2, 0.1, 4.2], [4, -1.9, 0.1, 4.7], [7, -4.7, 0.1, 5.3], [8, -6.8, 0.0, 5.8], [11, -11.1, 0.2, 7.2], [13, -13.3, 0.1, 7.8], [16, -15.2, 0.1, 8.2], [19, -15.8, 0.1, 8.3]]]),
    Phase(frames: 14, dots: [
        [[0, 15.4, 0.1, 8.4], [3, 13.6, 0.1, 8.1], [5, 10.8, 0.1, 7.5], [9, 3.3, 0.1, 6.0], [11, 1.0, 0.1, 5.6], [13, -0.0, 0.1, 5.5]],
        [[0, -0.0, 0.1, 4.0], [9, 0.2, 0.0, 5.0], [11, -0.5, -0.1, 5.8], [13, -0.2, -0.5, 4.6]],
        [[0, -15.7, 0.1, 8.3], [2, -14.8, 0.1, 8.1], [4, -12.7, 0.1, 7.9], [8, -5.2, 0.1, 6.4], [10, -2.3, 0.1, 5.7], [13, -0.7, 0.2, 4.8]]])]
private let readKeys: [Phase] = [Phase(frames: 21, dots: [
        [[0, 0.1, 0.0, 5.0], [2, 0.9, -0.7, 3.9], [8, 6.1, -2.9, 1.9], [13, 9.7, -3.2, 0.8], [20, 11.7, -3.2, 0.2]],
        [[0, -0.1, 0.0, 5.2], [5, 3.9, -2.2, 3.2], [11, 8.2, -4.0, 2.2], [12, -2.3, -1.5, 2.8], [16, -7.7, -4.5, 6.7], [19, -10.3, -5.9, 8.7], [20, -10.5, -6.1, 9.1]],
        [[0, -0.0, -0.1, 5.2], [6, 7.0, -4.0, 8.2], [10, 10.4, -6.2, 9.5], [15, 12.7, -7.4, 9.6], [20, 12.9, -7.4, 8.3]]]),
    Phase(frames: 60, dots: [
        [[0, 11.8, -3.2, 0.2], [1, 0.1, -2.5, 3.6], [5, 0.0, -8.0, 7.3], [10, 0.1, -12.8, 9.5], [15, -0.0, -14.9, 9.6], [19, -0.0, -14.8, 8.4], [21, -0.0, -13.6, 7.4], [24, -0.1, -9.7, 5.3], [27, 0.0, -3.8, 2.7], [29, 0.1, 0.1, 1.6], [31, -0.0, 2.9, 2.8], [34, 0.1, 7.6, 5.8], [38, 0.0, 11.9, 8.6], [41, 0.0, 13.6, 9.6], [47, -0.0, 15.1, 9.2], [50, 0.1, 14.6, 8.2], [53, 0.0, 12.1, 6.5], [55, -0.0, 8.9, 5.0], [58, -0.1, 2.0, 2.3], [59, -0.1, -0.0, 2.5]],
        [[0, -11.1, -6.4, 9.4], [6, -13.0, -7.4, 9.3], [9, -13.0, -7.5, 8.6], [11, -12.2, -7.0, 7.6], [14, -9.2, -5.3, 5.7], [19, -0.1, -0.1, 1.6], [24, 5.9, 3.4, 6.6], [28, 9.7, 5.6, 9.1], [32, 11.9, 6.9, 9.7], [37, 13.1, 7.5, 9.2], [40, 12.5, 7.2, 8.1], [42, 10.9, 6.3, 7.0], [45, 6.9, 4.0, 4.6], [49, 0.1, -0.0, 1.5], [50, -1.0, -0.7, 2.0], [55, -7.6, -4.5, 6.7], [58, -10.3, -6.0, 8.6], [59, -10.5, -6.1, 9.2]],
        [[0, 12.6, -7.2, 7.8], [3, 10.4, -6.0, 5.9], [7, 3.6, -2.2, 2.5], [9, 0.0, -0.1, 1.5], [10, -1.0, 0.5, 1.9], [14, -6.1, 3.4, 6.1], [18, -9.9, 5.6, 8.8], [23, -12.4, 7.2, 9.6], [28, -13.0, 7.5, 8.9], [31, -12.2, 7.0, 7.7], [34, -9.3, 5.3, 5.8], [39, -0.1, 0.1, 1.6], [44, 5.9, -3.3, 6.6], [49, 10.5, -6.0, 9.4], [53, 12.4, -7.1, 9.8], [59, 12.9, -7.4, 8.7]]]),
    Phase(frames: 19, dots: [
        [[0, -0.1, -0.0, 2.6], [5, 0.0, -0.0, 5.2], [18, -0.0, 0.0, 5.1]],
        [[0, -11.1, -6.4, 9.4], [6, -13.0, -7.4, 9.5], [9, -13.0, -7.5, 8.9], [11, -12.2, -7.1, 8.3], [14, -9.2, -5.3, 7.0], [16, -5.9, -3.5, 5.8], [18, -1.7, -1.1, 4.6]],
        [[0, 12.6, -7.2, 8.4], [3, 10.3, -6.0, 7.2], [5, 7.5, -4.3, 6.1], [9, 0.1, -0.1, 4.0], [10, -0.7, 0.3, 3.6], [18, -0.4, 1.2, 2.5]]])]
private let writeKeys: [Phase] = [Phase(frames: 31, dots: [
        [[0, 0.0, 0.0, 4.8, 5.2], [2, 0.6, 0.0, 3.7, 5.8], [4, 0.8, 0.7, 4.2, 5.7], [5, 0.4, 1.1, 4.9, 5.0], [6, -1.0, 2.7, 5.8, 4.2], [8, -1.4, 5.8, 6.6, 2.9], [11, -0.8, 3.6, 6.8, 0.1], [15, -0.5, 2.4, 7.0, -1.7], [16, 2.2, 5.0, 6.0, 5.1], [17, 1.9, 1.7, 8.7, 7.6], [19, 4.3, -3.3, 8.6, 8.9], [20, 5.5, -5.0, 8.4, 9.5], [21, 6.6, -6.3, 8.6, 10.0], [23, 8.9, -7.3, 8.8, 10.5], [25, 11.3, -6.3, 8.6, 10.1], [26, 12.5, -5.0, 8.6, 9.9], [27, 13.7, -3.1, 8.6, 9.6], [30, 17.2, 5.1, 8.6, 8.6]],
        [[0, -0.1, -0.7, 4.7, 5.2], [4, -0.2, 0.9, 6.2, 6.0], [6, -0.0, 3.5, 7.8, 5.8], [7, -0.0, 4.9, 8.4, 6.8], [8, -0.4, 5.2, 8.2, 7.1], [10, -2.4, -0.4, 8.4, 7.9], [12, -4.3, -4.5, 8.6, 9.3], [14, -6.3, -6.9, 8.6, 10.1], [16, -8.3, -7.3, 9.0, 10.3], [18, -10.4, -6.4, 8.7, 10.1], [20, -12.4, -4.3, 8.6, 9.8], [22, -14.4, -1.1, 8.6, 9.3], [25, -17.0, 5.1, 8.7, 8.6], [30, -17.0, 5.1, 8.6, 8.7]],
        [[0, -0.2, -0.2, 5.0, 5.3], [3, -0.2, 0.0, 5.2, 5.8], [6, 0.1, 2.8, 6.8, 6.0], [8, -0.0, 5.7, 7.6, 6.0], [9, -1.1, 3.4, 7.2, 5.8], [10, 0.0, 3.8, 7.8, 6.6], [11, 0.0, 5.3, 8.2, 6.9], [12, 0.0, 4.9, 8.6, 7.1], [13, 0.0, 2.0, 8.4, 7.6], [15, 0.0, 0.9, 8.7, 17.1], [16, -0.0, -0.9, 8.6, 18.1], [17, 0.1, -6.0, 8.6, 10.1], [19, 0.0, -7.3, 8.5, 10.1], [21, 0.2, -7.0, 8.8, 10.2], [24, 0.1, -4.1, 8.7, 9.7], [29, 0.1, 5.1, 8.6, 8.6], [30, 0.1, 5.1, 8.8, 8.5]]]),
    Phase(frames: 60, dots: [
        [[0, 17.2, 5.1, 8.5, 8.6], [9, 17.1, 5.1, 8.7, 8.6], [12, 17.1, -2.0, 8.7, 9.8], [14, 17.2, -5.9, 8.7, 10.5], [16, 17.2, -8.2, 8.7, 11.1], [19, 17.1, -9.4, 8.7, 11.7], [22, 17.1, -8.2, 8.7, 10.9], [24, 17.1, -6.0, 8.7, 9.5], [26, 17.1, -2.1, 8.6, 8.0], [29, 17.1, 6.2, 8.5, 6.0], [34, 17.1, -3.9, 8.8, 9.6], [37, 17.2, -7.2, 8.6, 11.2], [39, 17.1, -7.8, 8.7, 11.7], [41, 17.1, -7.3, 8.7, 11.4], [43, 17.1, -5.7, 8.8, 10.8], [45, 17.1, -2.8, 8.8, 10.3], [49, 17.2, 5.1, 8.8, 8.7], [59, 17.2, 5.1, 8.6, 8.6]],
        [[0, -17.0, 3.0, 8.7, 9.1], [2, -17.0, -2.0, 8.7, 9.7], [4, -17.0, -5.8, 8.6, 10.5], [6, -17.0, -8.2, 8.6, 11.2], [9, -17.0, -9.4, 8.7, 11.4], [12, -17.0, -8.3, 8.7, 10.7], [14, -17.0, -6.0, 8.8, 9.6], [16, -17.0, -2.1, 8.7, 8.0], [19, -17.0, 6.3, 8.7, 6.0], [24, -17.0, -3.9, 8.7, 9.6], [27, -17.0, -7.2, 8.6, 11.3], [29, -16.9, -7.7, 8.8, 11.5], [31, -16.9, -7.3, 8.8, 11.2], [34, -17.0, -4.5, 8.7, 10.6], [39, -17.0, 5.1, 8.5, 8.6], [59, -17.0, 5.1, 8.6, 8.7]],
        [[0, 0.1, 5.1, 8.8, 8.6], [4, 0.1, 5.1, 8.8, 8.7], [7, 0.1, -2.1, 8.8, 9.7], [9, 0.1, -5.9, 8.6, 10.5], [11, 0.1, -8.2, 8.6, 11.2], [13, 0.1, -9.3, 8.6, 11.6], [16, 0.0, -8.8, 8.7, 11.2], [19, 0.1, -6.0, 8.7, 9.5], [21, -0.0, -2.2, 8.5, 8.2], [24, 0.1, 6.2, 8.4, 6.2], [27, 0.1, -0.3, 8.4, 8.3], [29, 0.1, -3.9, 8.8, 9.7], [32, 0.1, -7.2, 8.8, 11.2], [34, 0.1, -7.7, 8.7, 11.6], [36, 0.1, -7.3, 8.6, 11.4], [39, 0.1, -4.4, 8.7, 10.7], [44, 0.2, 5.2, 8.6, 8.6], [59, 0.1, 5.1, 8.8, 8.5]]]),
    Phase(frames: 14, dots: [
        [[0, 17.1, 5.1, 8.6, 8.6], [3, 17.2, 5.1, 8.5, 8.6], [5, 16.3, 4.9, 8.6, 8.6], [6, 14.6, 4.3, 8.3, 8.3], [7, 10.8, 3.1, 7.5, 8.0], [8, 5.8, 1.2, 6.1, 7.6], [9, 2.8, 0.3, 5.6, 7.0], [10, 1.1, -0.4, 5.4, 5.5], [12, 0.1, -1.4, 3.8, 2.5], [13, -0.1, -1.8, 3.1, 1.6]],
        [[0, -16.8, 5.0, 8.6, 8.7], [1, -16.2, 4.8, 8.5, 8.6], [2, -14.5, 4.2, 8.4, 8.4], [3, -10.8, 3.0, 8.1, 8.2], [4, -5.8, 1.2, 7.6, 7.5], [5, -2.9, 0.8, 6.5, 6.2], [6, -1.4, 0.5, 5.7, 5.5], [7, -1.0, 0.3, 4.8, 5.1], [8, 0.2, 0.4, 6.2, 5.8], [9, 1.2, 0.4, 7.2, 5.5], [11, 0.7, 0.2, 4.9, 5.2], [13, 0.3, 0.0, 4.5, 5.0]],
        [[0, 0.1, 5.1, 8.8, 8.6], [4, 0.1, 4.3, 8.2, 8.4], [6, 0.1, 1.4, 6.5, 7.6], [8, 0.2, -0.1, 5.0, 5.9], [10, -0.1, -0.0, 4.8, 4.8], [13, -0.4, -0.1, 4.2, 4.7]]])]
private let codeKeys: [Phase] = [Phase(frames: 16, dots: [
        [[0, 0.1, -0.2, 5.8], [2, 0.2, -0.3, 6.2], [3, 0.2, -0.4, 7.0], [4, 0.5, -0.7, 7.7], [5, 1.6, -1.8, 7.3], [6, 3.7, -4.1, 7.1], [7, 6.6, -7.3, 7.8], [8, 8.7, -9.7, 8.4], [9, 9.8, -10.9, 8.7], [11, 10.9, -12.1, 9.0], [15, 11.3, -12.4, 9.1]],
        [[0, 0.4, 0.5, 5.3], [2, 0.6, 0.7, 5.3], [4, 0.8, 1.0, 6.9], [5, 2.0, 1.9, 6.9], [6, 3.9, 3.8, 7.2], [7, 7.1, 6.9, 7.9], [8, 9.3, 9.1, 8.4], [9, 10.4, 10.2, 8.7], [11, 11.7, 11.2, 9.2], [15, 11.9, 11.7, 9.2]],
        [[0, -0.7, 0.2, 5.0], [3, -0.9, 0.5, 5.8], [5, -2.0, 2.1, 6.8], [6, -3.6, 4.1, 7.3], [7, -6.6, 7.4, 7.9], [8, -8.6, 9.7, 8.4], [9, -9.7, 10.9, 8.7], [12, -11.1, 12.4, 9.0], [15, -11.1, 12.6, 9.2]],
        [[0, -0.2, -0.5, 5.5], [3, -0.8, -1.0, 5.2], [5, -1.9, -1.8, 7.0], [6, -3.8, -3.6, 7.3], [7, -6.8, -6.6, 7.7], [8, -9.0, -8.7, 8.1], [9, -10.1, -9.8, 8.4], [12, -11.4, -11.1, 8.9], [15, -11.5, -11.3, 9.0]]]),
    Phase(frames: 75, dots: [
        [[0, 11.6, -12.2, 9.1], [17, 12.0, -11.8, 9.2], [19, 11.9, -11.2, 9.2], [21, 11.5, -9.9, 9.3], [23, 10.6, -6.8, 9.5], [24, 9.5, -4.1, 9.6], [26, 6.3, 3.4, 9.7], [28, 1.0, 11.3, 9.6], [29, -1.9, 13.9, 9.4], [30, -4.3, 15.1, 9.3], [31, -6.4, 15.2, 9.2], [34, -10.0, 13.6, 9.1], [38, -11.5, 12.2, 9.1], [53, -11.8, 11.7, 8.9], [56, -11.4, 11.2, 8.9], [58, -10.9, 9.9, 8.9], [60, -9.8, 7.3, 8.8], [61, -9.0, 5.1, 8.7], [63, -6.4, -1.0, 8.6], [65, -2.1, -8.6, 8.6], [66, 0.5, -11.8, 8.7], [67, 3.1, -13.7, 8.8], [68, 5.3, -14.4, 8.8], [70, 8.6, -14.1, 8.9], [74, 12.0, -11.8, 9.1]],
        [[0, 11.9, 11.4, 9.2], [3, 11.3, 9.1, 9.3], [5, 9.9, 5.0, 9.6], [6, 8.5, 1.8, 9.6], [7, 6.8, -2.2, 9.5], [9, 1.7, -10.5, 9.4], [10, -1.1, -13.3, 9.6], [11, -3.7, -14.8, 9.6], [12, -5.9, -15.1, 9.2], [15, -9.8, -13.5, 9.1], [19, -11.4, -12.2, 9.0], [34, -11.7, -11.7, 9.0], [37, -11.4, -11.2, 8.8], [39, -11.0, -10.0, 8.7], [41, -10.1, -7.6, 8.6], [42, -9.3, -5.7, 8.6], [44, -6.8, 0.3, 8.4], [47, -0.2, 11.2, 8.6], [48, 2.5, 13.4, 8.7], [49, 4.8, 14.4, 8.7], [50, 6.8, 14.6, 8.9], [52, 9.5, 13.8, 8.9], [55, 11.3, 12.6, 9.0], [62, 11.9, 11.9, 8.9], [74, 11.9, 12.0, 9.1]],
        [[0, -11.3, 12.4, 9.2], [15, -11.8, 11.8, 9.0], [20, -11.1, 10.2, 8.9], [22, -10.2, 8.0, 8.8], [23, -9.5, 6.2, 8.7], [24, -8.6, 3.9, 8.6], [25, -7.3, 0.7, 8.6], [26, -5.5, -3.0, 8.6], [28, -0.8, -10.3, 8.6], [29, 1.7, -12.8, 8.7], [30, 4.2, -14.2, 8.8], [31, 6.3, -14.6, 9.0], [34, 10.0, -13.3, 9.1], [38, 11.7, -12.2, 9.2], [54, 12.0, -11.8, 9.2], [57, 11.8, -11.1, 9.4], [59, 11.3, -9.4, 9.5], [61, 10.1, -5.5, 9.5], [62, 8.9, -2.6, 9.6], [63, 7.2, 1.3, 9.6], [65, 2.5, 9.7, 9.6], [66, -0.3, 12.9, 9.5], [67, -3.0, 14.6, 9.3], [68, -5.4, 15.2, 9.2], [70, -8.7, 14.5, 9.2], [74, -11.8, 12.0, 9.1]],
        [[0, -11.4, -10.9, 9.0], [3, -10.3, -8.3, 8.8], [4, -9.7, -6.7, 8.7], [6, -7.6, -1.5, 8.6], [8, -3.9, 6.0, 8.6], [10, 1.2, 12.4, 8.7], [11, 3.7, 14.1, 8.9], [12, 5.8, 14.6, 8.9], [15, 9.9, 13.6, 9.1], [18, 11.5, 12.5, 9.2], [23, 12.0, 12.0, 9.2], [35, 12.0, 11.9, 9.0], [39, 11.7, 10.6, 9.3], [41, 11.0, 8.3, 9.5], [42, 10.3, 6.3, 9.5], [44, 7.7, -0.2, 9.5], [46, 3.2, -8.6, 9.7], [47, 0.4, -12.0, 9.5], [48, -2.4, -14.2, 9.3], [49, -4.9, -15.1, 9.2], [50, -6.8, -15.0, 9.1], [52, -9.3, -13.9, 9.0], [55, -11.1, -12.5, 9.0], [61, -11.8, -11.8, 9.2], [74, -11.8, -11.9, 9.1]]]),
    Phase(frames: 9, dots: [
        [[0, 11.8, -11.7, 9.1], [2, 10.2, -10.1, 8.6], [3, 7.5, -7.5, 8.0], [4, 3.5, -3.4, 6.9], [5, 1.4, 1.4, 6.5], [6, 0.1, 1.9, 3.9], [8, -1.9, 2.4, 0.2]],
        [[0, 11.8, 11.8, 9.0], [2, 10.3, 10.2, 8.6], [3, 7.6, 7.5, 8.0], [4, 3.5, 3.5, 7.0], [5, 1.4, -1.4, 6.7], [6, 0.0, -2.1, 3.5], [8, -1.8, -3.1, -1.0]],
        [[0, -11.6, 11.8, 9.1], [2, -10.1, 10.2, 8.7], [3, -7.4, 7.5, 8.0], [4, -3.4, 3.5, 7.1], [5, -1.5, 1.4, 6.5], [7, 0.0, -0.0, 6.5], [8, -0.0, -0.1, 6.1]],
        [[0, -11.7, -11.7, 9.1], [2, -10.1, -10.1, 8.7], [3, -7.5, -7.4, 8.1], [4, -3.4, -3.3, 7.1], [5, -1.3, -1.1, 7.1], [6, 0.1, 0.0, 7.5], [7, 0.2, 0.1, 6.3], [8, 0.3, 0.1, 6.0]]])]
