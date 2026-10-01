import SwiftUI
import UIKit

struct NativeSearchField: UIViewRepresentable {
    let search: SearchService
    let onFocus: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UISearchTextField {
        let field = UISearchTextField()
        field.placeholder = "Search Apple Maps"
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.font = .preferredFont(forTextStyle:.body)
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.clearButtonMode = .never
        let clear = UIButton(type:.system)
        clear.setImage(UIImage(systemName:"xmark.circle.fill"),for:.normal)
        clear.tintColor = .secondaryLabel; clear.accessibilityLabel = "Clear search"
        clear.frame = CGRect(x:0,y:0,width:28,height:28); clear.isHidden = search.query.isEmpty
        clear.addTarget(context.coordinator,action:#selector(Coordinator.clear),for:.touchUpInside)
        field.rightView = clear; field.rightViewMode = .always
        field.accessibilityIdentifier = "search.field"
        field.delegate = context.coordinator
        field.addTarget(context.coordinator,action:#selector(Coordinator.changed(_:)),for:.editingChanged)
        field.setContentHuggingPriority(.defaultLow,for:.horizontal)
        field.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        field.text = search.query
        context.coordinator.field = field
        search.onDismissKeyboard = { [weak field] in field?.resignFirstResponder() }
        return field
    }
    func updateUIView(_ field: UISearchTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.inputRevision != search.inputRevision {
            coordinator.inputRevision = search.inputRevision; field.text = search.query
        } else if !field.isFirstResponder, field.text != search.query { field.text = search.query }
        if coordinator.focusRelease != search.focusRelease {
            coordinator.focusRelease = search.focusRelease; field.resignFirstResponder()
        }
        field.rightView?.isHidden = (field.text ?? "").isEmpty
    }
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativeSearchField
        weak var field: UISearchTextField?
        var inputRevision: Int
        var focusRelease: Int
        #if DEBUG
        private let probe = SearchInteractionProbe()
        #endif
        init(_ parent: NativeSearchField) {
            self.parent = parent; inputRevision = parent.search.inputRevision; focusRelease = parent.search.focusRelease
        }
        func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
            #if DEBUG
            probe.begin()
            #endif
            return true
        }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            // UIKit may probe shouldBeginEditing without actually focusing (notably iPad).
            // didBeginEditing still precedes the keyboard animation and confirms real input.
            parent.search.setFocused(true); parent.onFocus(true)
            #if DEBUG
            probe.didBeginEditing()
            #endif
        }
        func textFieldDidEndEditing(_ textField: UITextField) {
            #if DEBUG
            probe.finish()
            #endif
            parent.search.setFocused(false); parent.onFocus(false)
        }
        @objc func changed(_ field: UITextField) {
            #if DEBUG
            let start = CACurrentMediaTime()
            defer { probe.edit(duration:CACurrentMediaTime()-start) }
            #endif
            field.rightView?.isHidden = (field.text ?? "").isEmpty
            guard field.markedTextRange == nil else { return }
            parent.search.edit(field.text ?? "")
        }
        @objc func clear() { field?.text = ""; field?.rightView?.isHidden = true; parent.search.clear() }
        func textFieldShouldClear(_ textField: UITextField) -> Bool { parent.search.clear(); return true }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.search.edit(textField.text ?? ""); parent.search.submit(); textField.resignFirstResponder(); return true
        }
    }
}
