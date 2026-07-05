//
//  Item.swift
//  Room Capsule
//
//  Created by Hibiki Tsuboi on 2026/07/05.
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
