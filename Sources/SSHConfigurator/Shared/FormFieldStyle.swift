import SwiftUI

extension View {
    /// Editör formlarındaki metin alanlarına görünür kutu kazandırır; boş
    /// alanlar da bir girdi olduğunu belli etsin diye kullanılır.
    func editorFieldStyle() -> some View {
        textFieldStyle(.roundedBorder)
    }
}
