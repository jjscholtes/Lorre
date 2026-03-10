import SwiftUI

struct SearchFieldView: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x1_5) {
            CapsLabel(text: label)

            HStack(spacing: DS.Space.x2) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .font(.system(size: 12, weight: .semibold))

                TextField("Search sessions", text: $text)
                    .textFieldStyle(.plain)
                    .font(DS.FontStyle.body)
                    .foregroundStyle(DS.ColorToken.fieldText)

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.ColorToken.fgTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, DS.Space.x3)
            .padding(.vertical, DS.Space.x2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DS.ColorToken.fieldBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(DS.ColorToken.fieldBorder, lineWidth: 1)
            )
        }
    }
}
