//
//  Item.swift
//  Crypto miner
//
//  Created by Tyler Charles on 2/28/26.
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
