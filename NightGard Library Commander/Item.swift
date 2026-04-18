//
//  Item.swift
//  NightGard Library Commander
//
//  Created by Michael Fluharty on 4/18/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
