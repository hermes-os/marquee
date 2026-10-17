import SwiftUI

// MARK: - VideoSurfaceView

struct VideoSurfaceView: NSViewRepresentable {

    let playerService: MPVPlayerService

    func makeNSView(context: Context) -> MPVOGLView {
        let view = MPVOGLView()
        view.autoresizingMask = [.width, .height]
        view.playerService = playerService
        return view
    }

    func updateNSView(_ nsView: MPVOGLView, context: Context) {
        guard nsView.playerService !== playerService else { return }

        nsView.playerService?.detachRenderView()
        nsView.playerService = playerService

        if nsView.window != nil {
            playerService.attachRenderView(nsView)
        }
    }
}
