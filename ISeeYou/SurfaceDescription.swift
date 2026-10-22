import Foundation
import CoreGraphics

// A central depth patch, not a wall/door classification or a safe walking path.
enum SurfaceDepthSampling {
    static let bounds = CGRect(x: 0.32, y: 0.35, width: 0.36, height: 0.40)
    static func read(width: Int, height: Int, value: (Int, Int) -> Double) -> ObjectDistance? {
        var rows: [[Double]] = [[], [], []]
        var cells: [Double] = []
        for row in 0..<3 { for column in 0..<3 {
            let box = CGRect(x: bounds.minX + CGFloat(column) * bounds.width / 3,
                y: bounds.minY + CGFloat(row) * bounds.height / 3,
                width: bounds.width / 3, height: bounds.height / 3)
            if let sample = DepthSampling.read(bounds: box, width: width, height: height, value: value) {
                rows[row].append(sample.metres); cells.append(sample.metres)
            }
        } }
        guard cells.count >= 8, rows.allSatisfy({ $0.count >= 2 }) else { return nil }
        cells.sort()
        let median = cells[cells.count / 2]
        guard (0.15...3).contains(median),
              cells.last! - cells.first! <= max(0.20, median * 0.25) else { return nil }
        // Reject strong vertical depth gradients (often a receding floor).
        // This heuristic is not floor recognition; a level view is still required.
        let rowMedians = rows.map { $0.sorted()[$0.count / 2] }
        guard abs(rowMedians[0] - rowMedians[2]) <= max(0.15, median * 0.20) else { return nil }
        return ObjectDistance(metres: median, spread: cells.last! - cells.first!,
                              coverage: Double(cells.count) / 9)
    }
}

struct SurfaceAnnouncementPolicy {
    private var firstSeen: TimeInterval?
    private var lastSeen: TimeInterval?
    private var lastMetres: Double?
    private var lastSpoken: TimeInterval = -.infinity
    mutating func update(_ reading: ObjectDistance?, at time: TimeInterval, scale: Double?) -> SpokenAlert? {
        let metres = (reading?.metres ?? .nan) * (scale ?? 1)
        guard time.isFinite, metres.isFinite, (0.15...3).contains(metres),
              let reading, reading.coverage >= 0.8 else {
            firstSeen = nil; lastSeen = nil; lastMetres = nil
            return nil
        }
        if let lastSeen, time < lastSeen || time - lastSeen > 0.5 {
            firstSeen = nil
        }
        if let previous = lastMetres, abs(previous - metres) > max(0.2, metres * 0.2) { firstSeen = nil }
        if firstSeen == nil { firstSeen = time }
        lastSeen = time; lastMetres = metres
        guard time - firstSeen! >= 1, time - lastSpoken >= 8 else { return nil }
        lastSpoken = time
        let message = "Surface ahead, approximately " + String(format: "%.1f", metres) + " metres" + (metres < 0.5 ? ", very close" : "")
        return SpokenAlert(level: .caution, message: message)
    }
}
