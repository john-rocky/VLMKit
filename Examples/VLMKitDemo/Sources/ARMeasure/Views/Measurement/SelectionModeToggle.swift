//
//  SelectionModeToggle.swift
//  SnapMeasure
//

import SwiftUI

struct SelectionModeToggle: View {
    @Binding var selectionMode: SelectionMode

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SelectionMode.allCases, id: \.self) { mode in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectionMode = mode
                    }
                }) {
                    Image(systemName: mode.icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(selectionMode == mode ? .white : PMTheme.textSecondary)
                        .frame(width: 32, height: 32)
                    .background(
                        selectionMode == mode
                            ? PMTheme.cyan.opacity(0.80)
                            : Color.clear
                    )
                    .clipShape(Capsule())
                }
            }
        }
        .padding(4)
        .background(PMTheme.surfaceDark.opacity(0.85))
        .overlay(
            Capsule()
                .strokeBorder(PMTheme.cyan.opacity(0.20), lineWidth: 0.5)
        )
        .clipShape(Capsule())
    }
}

#Preview {
    ZStack {
        Color.black
        SelectionModeToggle(selectionMode: .constant(.tap))
    }
}
