// ResourceSessionPickerView.swift
// Session picker for selecting target session for resource uploads

import SwiftUI
import CoreData

struct ResourceSessionPickerView: View {
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \CDBackendSession.lastModified, ascending: false)],
        animation: .default
    )
    private var sessions: FetchedResults<CDBackendSession>

    let onSelect: (CDBackendSession) -> Void
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
                            CDBackendSessionRowContent(session: session)
                        }
                    }
                }
            }
            .navigationTitle("Select Session")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
                #else
                ToolbarItem(placement: .automatic) {
                    Button("Cancel", action: onCancel)
                }
                #endif
            }
        }
    }
}
