import SwiftUI

struct CapsLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.FontStyle.control)
            .tracking(0.8)
            .foregroundStyle(DS.ColorToken.fgSecondary)
            .textCase(.uppercase)
    }
}
