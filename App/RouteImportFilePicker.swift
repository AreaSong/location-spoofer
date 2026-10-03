import SwiftUI
import UniformTypeIdentifiers

/// 每次展示独占回调；明确接收系统取消事件，避免取消后残留旧选择请求。
struct RouteImportFilePicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onResult: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Delegate { Delegate(onResult: onResult) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    final class Delegate: NSObject, UIDocumentPickerDelegate {
        private let onResult: (Result<URL, Error>) -> Void
        init(onResult: @escaping (Result<URL, Error>) -> Void) { self.onResult = onResult }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onResult(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onResult(.failure(CancellationError()))
        }
    }
}
