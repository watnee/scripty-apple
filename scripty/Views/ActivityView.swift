//
//  ActivityView.swift
//  scripty
//
//  A screenplay's recent activity — who did what, most recent first.
//
//  Read-only, because the log is written by the services that perform the
//  actions. An activity feed a client can post to is not a record of what
//  happened, only of what someone said happened.
//

import SwiftUI

struct ActivityView: View {
    @State private var model: ActivityModel

    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, source: HALLink) {
        _model = State(initialValue: ActivityModel(app: app, source: source))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: entry.systemImage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.displaySummary)
                                .font(.callout)
                            HStack(spacing: 4) {
                                Text(entry.displayActor)
                                if let created = entry.createdAt {
                                    Text("· \(created, format: .relative(presentation: .named))")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.plain)
            .overlay { emptyState }
            .navigationTitle("Recent Activity")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.load() }
            .refreshable { await model.load() }
            .alert("Error", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.entries.isEmpty {
            if model.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock",
                    description: Text("Changes to this screenplay will appear here."))
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } })
    }
}
