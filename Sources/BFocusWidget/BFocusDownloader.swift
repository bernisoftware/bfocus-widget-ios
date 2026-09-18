#if canImport(UIKit) && os(iOS)
import UIKit
import BFocusWidgetCore

/// Como oferecer o anexo baixado (`bfocus:download`).
public enum BFocusDownloadStyle: Sendable {
    /// Folha de compartilhamento (inclui "Salvar em Arquivos", AirDrop, abrir em outro app).
    case share
    /// "Salvar como" direto no seletor de pastas do app Arquivos.
    case saveToFiles
}

enum BFocusDownloader {
    /// Baixa para um diretório temporário com o nome dado. A URL é pré-assinada e expira:
    /// baixa na hora, sem cache.
    static func fetch(_ url: URL, filename: String, session: URLSession = .shared) async throws -> URL {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        request.httpMethod = "GET"
        let (temporary, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw URLError(.badServerResponse)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bfocus-downloads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(BFocusFileName.sanitize(filename, fallback: url.lastPathComponent))
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    @MainActor
    static func present(_ file: URL, style: BFocusDownloadStyle, from presenter: UIViewController) {
        switch style {
        case .share:
            let controller = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                // iPad exige âncora.
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            presenter.present(controller, animated: true)
        case .saveToFiles:
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            presenter.present(picker, animated: true)
        }
    }
}
#endif
