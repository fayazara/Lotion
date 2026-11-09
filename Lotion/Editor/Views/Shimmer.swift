//
//  Shimmer.swift
//  Lotion
//
//  A soft band of light that sweeps across placeholders while what they
//  stand for loads. One layer per view, masked to the placeholder shapes;
//  still when Reduce Motion is on.
//

import AppKit

final class Shimmer {
    private let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()
    private weak var host: NSView?

    init() {
        gradient.startPoint = CGPoint(x: 0, y: 0.35)
        gradient.endPoint = CGPoint(x: 1, y: 0.65)
        gradient.mask = mask
        gradient.zPosition = 10
    }

    /// Shows the shimmer over `rects` (in the view's coordinates), or removes it when there are none.
    /// `restart` re-adds the sweep, for a view that has just come on screen:
    /// an animation added while its window was off screen can stay frozen.
    func update(_ rects: [NSRect], radius: CGFloat, in view: NSView, isDark: Bool, restart: Bool = false) {
        guard !rects.isEmpty else {
            stop()
            return
        }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if gradient.superlayer !== layer {
            layer.addSublayer(gradient)
            host = view
        }
        gradient.frame = layer.bounds
        mask.frame = gradient.bounds
        let path = CGMutablePath()
        for rect in rects {
            // Layers of flipped views keep the view's coordinates.
            path.addRoundedRect(in: rect, cornerWidth: min(radius, rect.width / 2), cornerHeight: min(radius, rect.height / 2))
        }
        mask.path = path
        // A low, wide glow that eases in and out, rather than a bright stripe.
        // Every stop is white, not `clear` (transparent black), or the band's
        // edges blend through gray and smudge light surfaces.
        let peak: CGFloat = isDark ? 0.05 : 0.4
        gradient.colors = [0, 0.35, 1, 0.35, 0].map { NSColor.white.withAlphaComponent(peak * $0).cgColor }
        CATransaction.commit()
        animate()
    }

    var isActive: Bool { gradient.superlayer != nil }

    /// Where the band is drawn right now, for checking that it moves.
    var currentLocation: Double? {
        (gradient.locations?[2] as? NSNumber)?.doubleValue
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        gradient.removeFromSuperlayer()
        host = nil
    }

    // The band is moved every frame by a display link rather than left to a
    // CoreAnimation animation, which stalled whenever its window was moved.
    private var displayLink: CADisplayLink?
    private static let period: Double = 1.8

    private func animate() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            displayLink?.invalidate()
            displayLink = nil
            setPhase(0.5)
            return
        }
        guard displayLink == nil, let host else { return }
        let link = host.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
        tick()
    }

    @objc private func tick() {
        // Every shimmer shares the clock, so several sweep together.
        let time = CACurrentMediaTime().truncatingRemainder(dividingBy: Self.period) / Self.period
        // Ease in and out across the sweep.
        setPhase(time < 0.5 ? 2 * time * time : 1 - pow(-2 * time + 2, 2) / 2)
    }

    /// 0 has the band at the leading edge, 1 at the trailing one; always partly in view.
    private func setPhase(_ phase: Double) {
        let center = -0.3 + 1.6 * phase
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.locations = [center - 0.45, center - 0.2, center, center + 0.2, center + 0.45].map { NSNumber(value: $0) }
        CATransaction.commit()
    }
}
