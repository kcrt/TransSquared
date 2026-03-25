import SwiftUI

/// An NSViewRepresentable that wraps NSVisualEffectView to provide a frosted glass background.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let alphaValue: CGFloat

    init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        alphaValue: CGFloat = 1.0
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.alphaValue = alphaValue
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.alphaValue = alphaValue
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.alphaValue = alphaValue
    }
}
