import SwiftUI
import UIKit

public extension View {
    func shakeFeedbackDetector(perform action: @escaping () -> Void) -> some View {
        background(ShakeFeedbackDetectorRepresentable(action: action))
    }
}

private struct ShakeFeedbackDetectorRepresentable: UIViewControllerRepresentable {
    let action: () -> Void

    func makeUIViewController(context: Context) -> ShakeFeedbackDetectorViewController {
        let controller = ShakeFeedbackDetectorViewController()
        controller.onShake = action
        return controller
    }

    func updateUIViewController(_ uiViewController: ShakeFeedbackDetectorViewController, context: Context) {
        uiViewController.onShake = action
    }
}

private final class ShakeFeedbackDetectorViewController: UIViewController {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        activateFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        activateFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            DispatchQueue.main.async { [onShake] in onShake?() }
        }
        super.motionEnded(motion, with: event)
    }

    private func activateFirstResponder() {
        guard view.window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }
}

