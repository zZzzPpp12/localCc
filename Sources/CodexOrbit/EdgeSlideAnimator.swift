import Foundation

@MainActor
final class EdgeSlideAnimator {
    private var timer: Timer?
    private var revision = 0
    private var target: Double?
    var isRunning: Bool { timer != nil }

    func stop() {
        revision += 1
        timer?.invalidate(); timer = nil; target = nil
    }

    func move(from start: Double, to destination: Double, animated: Bool, update: @escaping (Double) -> Void) {
        let distance = abs(destination - start)
        if !animated || distance < 0.0001 {
            stop(); update(destination); return
        }
        if timer != nil, target == destination { return }
        stop()
        target = destination
        let generation = revision
        let began = ProcessInfo.processInfo.systemUptime
        // Reversing uses the current presentation value and a shorter duration.
        let duration = max(0.10, 0.24 * distance)
        let clock = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.revision == generation else { return }
                let elapsed = (ProcessInfo.processInfo.systemUptime - began) / duration
                let amount = EdgeDockGeometry.slideEase(elapsed)
                if elapsed >= 1 { self.stop(); update(destination) }
                else { update(start + (destination - start) * amount) }
            }
        }
        timer = clock
        RunLoop.main.add(clock, forMode: .common)
    }
}
