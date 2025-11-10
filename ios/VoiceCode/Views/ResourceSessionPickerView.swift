// ResourceSessionPickerView.swift
// Session picker for selecting target session for resource uploads

import SwiftUI
import CoreData

struct ResourceSessionPickerView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \CDSession.lastModified, ascending: false)],
        animation: .default
    )
    private var sessions: FetchedResults<CDSession>

    let onSelect: (CDSession) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                if sessions.isEmpty {
                    Text("No sessions available")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    ForEach(sessions) { session in
                        Button(action: {
                            onSelect(session)
                        }) {
                            CDSessionRowContent(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Select Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
