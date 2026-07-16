//
//  MyApp.swift
//  crabfitapple
//
//  Created by Ben Woo on 9/7/26.
//

import SwiftData
import SwiftUI

@main struct MyApp: App {
    private let modelContainer: ModelContainer = {
        let schema = Schema([SavedEvent.self])
        let configuration = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private("iCloud.com.benthecat.crabfit")
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create SwiftData model container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            EventListView()
                .tint(.orange)
        }
        .modelContainer(modelContainer)
    }
}
