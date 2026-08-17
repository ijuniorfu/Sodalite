import SwiftUI
import UIKit

/// UIKit UITextField wrapper: on tvOS it's a first-class focus-engine citizen (clean tab-bar/results routing, reliable keyboard overlay) where SwiftUI's TextField has focus quirks.
struct SearchTextField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        // tvOS UITextField defaults to a large font; 26pt keeps the inline bar slim.
        field.font = UIFont.systemFont(ofSize: 26, weight: .regular)
        field.delegate = context.coordinator
        field.addTarget(
            context.coordinator,
            action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged
        )
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Clear button, iOS only: UIKit draws it inside the field at the trailing edge, where iOS
        // looks for it, and localizes and voices it for free. tvOS has no pointer to hit it with.
        // .always rather than .whileEditing so it survives the keyboard being dismissed, which is
        // exactly when a stale query is in the way.
        #if os(iOS)
        field.clearButtonMode = .always
        #endif
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        uiView.placeholder = placeholder
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SearchTextField

        init(_ parent: SearchTextField) {
            self.parent = parent
        }

        @objc func editingChanged(_ sender: UITextField) {
            parent.text = sender.text ?? ""
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            textField.resignFirstResponder()
            return true
        }

        #if os(iOS)
        /// The clear button does not post .editingChanged, so the binding is published here or the
        /// field empties while the results below keep showing the old query's hits.
        func textFieldShouldClear(_ textField: UITextField) -> Bool {
            parent.text = ""
            return true
        }
        #endif
    }
}
