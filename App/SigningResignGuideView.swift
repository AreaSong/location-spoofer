import SwiftUI

struct SigningResignGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Text(SigningExpiry.resignInstructions)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding()
                .navigationTitle("重新签名")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}
