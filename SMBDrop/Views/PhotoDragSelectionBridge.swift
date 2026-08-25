import SwiftUI
import UIKit

/// Adds Photos-style range selection to a SwiftUI scroll view. A horizontal
/// start becomes selection and prevents the grid from moving under the finger;
/// a vertical start fails immediately so the scroll view behaves normally.
/// Holding a selection drag near an edge scrolls the grid automatically.
struct PhotoDragSelectionBridge: UIViewRepresentable {
    let isEnabled: Bool
    let onBegan: (CGPoint) -> Void
    let onChanged: (CGPoint) -> Void
    let onEnded: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        context.coordinator.hostView = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.onBegan = onBegan
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            isEnabled: isEnabled,
            onBegan: onBegan,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var hostView: UIView?
        weak var scrollView: UIScrollView?
        var isEnabled: Bool {
            didSet { panRecognizer.isEnabled = isEnabled }
        }
        var onBegan: (CGPoint) -> Void
        var onChanged: (CGPoint) -> Void
        var onEnded: () -> Void

        private var displayLink: CADisplayLink?
        private var lastWindowPoint: CGPoint?

        private lazy var panRecognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(
                target: self,
                action: #selector(handlePan(_:))
            )
            recognizer.delegate = self
            recognizer.maximumNumberOfTouches = 1
            recognizer.cancelsTouchesInView = true
            recognizer.isEnabled = isEnabled
            return recognizer
        }()

        init(
            isEnabled: Bool,
            onBegan: @escaping (CGPoint) -> Void,
            onChanged: @escaping (CGPoint) -> Void,
            onEnded: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.onBegan = onBegan
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        func installIfNeeded() {
            guard scrollView == nil,
                  let scrollView = hostView?.firstSuperview(of: UIScrollView.self) else {
                return
            }
            self.scrollView = scrollView
            scrollView.addGestureRecognizer(panRecognizer)
            scrollView.panGestureRecognizer.require(toFail: panRecognizer)
        }

        func uninstall() {
            stopAutoScroll()
            scrollView?.removeGestureRecognizer(panRecognizer)
            scrollView = nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard isEnabled,
                  let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }
            let velocity = pan.velocity(in: scrollView)
            return abs(velocity.x) > abs(velocity.y)
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let window = scrollView?.window else { return }
            let point = recognizer.location(in: window)
            lastWindowPoint = point

            switch recognizer.state {
            case .began:
                onBegan(point)
                startAutoScroll()
            case .changed:
                onChanged(point)
            case .ended, .cancelled, .failed:
                stopAutoScroll()
                lastWindowPoint = nil
                onEnded()
            default:
                break
            }
        }

        private func startAutoScroll() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(autoScroll))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopAutoScroll() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func autoScroll() {
            guard let scrollView, let window = scrollView.window, let point = lastWindowPoint else {
                return
            }
            let visibleFrame = scrollView.convert(scrollView.bounds, to: window)
            let edgeDepth: CGFloat = 56
            let delta: CGFloat
            if point.y < visibleFrame.minY + edgeDepth {
                delta = -max(2, (visibleFrame.minY + edgeDepth - point.y) / 5)
            } else if point.y > visibleFrame.maxY - edgeDepth {
                delta = max(2, (point.y - (visibleFrame.maxY - edgeDepth)) / 5)
            } else {
                return
            }

            let minimumY = -scrollView.adjustedContentInset.top
            let maximumY = max(
                minimumY,
                scrollView.contentSize.height
                    - scrollView.bounds.height
                    + scrollView.adjustedContentInset.bottom
            )
            let nextY = min(maximumY, max(minimumY, scrollView.contentOffset.y + delta))
            guard nextY != scrollView.contentOffset.y else { return }
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: nextY),
                animated: false
            )
            onChanged(point)
        }
    }
}

private extension UIView {
    func firstSuperview<T: UIView>(of type: T.Type) -> T? {
        var candidate = superview
        while let current = candidate {
            if let match = current as? T { return match }
            candidate = current.superview
        }
        return nil
    }
}
