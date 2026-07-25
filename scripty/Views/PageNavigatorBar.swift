//
//  PageNavigatorBar.swift
//  scripty
//
//  The floating "Page 3 of 12" pager from the web app: step through the script
//  a sheet at a time, type a page number to jump, and zoom the sheet. It only
//  appears in page view, and only once there is something to page through.
//

import SwiftUI

struct PageNavigatorBar: View {
    @Bindable var settings: PresentationSettings
    let pageCount: Int
    @Binding var currentPage: Int
    /// Asks the enclosing scroll view to bring a page into position.
    let onJump: (Int) -> Void

    @State private var typedPage: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            stepper(
                systemImage: "chevron.left",
                label: "Previous Page",
                disabled: currentPage <= 1) {
                    jump(to: currentPage - 1)
                }

            HStack(spacing: 4) {
                Text("Page")
                    .foregroundStyle(.secondary)

                TextField("", text: $typedPage)
                    .frame(width: 34)
                    .multilineTextAlignment(.center)
                    .textFieldStyle(.roundedBorder)
                    #if !os(macOS)
                    .keyboardType(.numberPad)
                    #endif
                    .focused($fieldFocused)
                    .onSubmit(commitTypedPage)
                    .accessibilityLabel("Page number")

                Text("of \(pageCount)")
                    .foregroundStyle(.secondary)
            }
            .font(.footnote)

            stepper(
                systemImage: "chevron.right",
                label: "Next Page",
                disabled: currentPage >= pageCount) {
                    jump(to: currentPage + 1)
                }

            Divider().frame(height: 18)

            stepper(
                systemImage: "minus.magnifyingglass",
                label: "Zoom Out",
                disabled: !settings.canZoomOut) {
                    settings.zoomOut()
                }

            Button {
                settings.resetZoom()
            } label: {
                Text("\(settings.effectiveZoom)%")
                    .font(.footnote.monospacedDigit())
                    .frame(width: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reset zoom to 100 percent")

            stepper(
                systemImage: "plus.magnifyingglass",
                label: "Zoom In",
                disabled: !settings.canZoomIn) {
                    settings.zoomIn()
                }

            stepper(
                systemImage: "arrow.left.and.right.square",
                label: "Fit to Width",
                disabled: false,
                isOn: settings.isPageZoomFit) {
                    settings.toggleFitZoom()
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.bottom, 12)
        // Keep the field in step with scrolling, but never yank the text out
        // from under someone who is mid-edit.
        .onChange(of: currentPage) { _, page in
            if !fieldFocused { typedPage = "\(page)" }
        }
        .onAppear { typedPage = "\(currentPage)" }
    }

    private func stepper(
        systemImage: String,
        label: String,
        disabled: Bool,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .frame(width: 28, height: 24)
                .background {
                    if isOn {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.accentColor.opacity(0.18))
                    }
                }
                // A 28×24 glyph is well under the 44pt touch minimum. The
                // padding grows the tappable area and the negative outer
                // padding gives it back, so the bar draws exactly as before —
                // 40pt wide rather than the full 44 so 6pt-spaced neighbours
                // only meet instead of overlapping.
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -10)
        .padding(.horizontal, -6)
        .disabled(disabled)
        .foregroundStyle(foreground(disabled: disabled, isOn: isOn))
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func foreground(disabled: Bool, isOn: Bool) -> AnyShapeStyle {
        if disabled { return AnyShapeStyle(.tertiary) }
        return isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary)
    }

    private func commitTypedPage() {
        guard let requested = Int(typedPage.trimmingCharacters(in: .whitespaces)) else {
            typedPage = "\(currentPage)"
            return
        }
        jump(to: requested)
        fieldFocused = false
    }

    private func jump(to page: Int) {
        let clamped = min(max(1, page), max(1, pageCount))
        currentPage = clamped
        typedPage = "\(clamped)"
        onJump(clamped)
    }
}
