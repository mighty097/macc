import Foundation
import CoreGraphics

enum SnowIntensity: Int, CaseIterable {
    case light = 0
    case normal = 1
    case heavy = 2

    var title: String {
        switch self {
        case .light: return "Лёгкий снег"
        case .normal: return "Обычный снег"
        case .heavy: return "Метель"
        }
    }

    var spawnChancePerFrame: CGFloat {
        switch self {
        case .light: return 0.18
        case .normal: return 0.46
        case .heavy: return 0.90
        }
    }

    var maximumParticles: Int {
        switch self {
        case .light: return 130
        case .normal: return 280
        case .heavy: return 480
        }
    }

    var maximumPileHeight: CGFloat {
        switch self {
        case .light: return 14
        case .normal: return 24
        case .heavy: return 38
        }
    }

    var fallSpeed: ClosedRange<CGFloat> {
        switch self {
        case .light: return 22...38
        case .normal: return 30...55
        case .heavy: return 42...76
        }
    }
}
