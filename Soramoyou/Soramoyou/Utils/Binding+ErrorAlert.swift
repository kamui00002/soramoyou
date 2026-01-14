//
//  Binding+ErrorAlert.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

extension Binding where Value == Bool {
    init(errorMessage: Binding<String?>) {
        self.init(
            get: { errorMessage.wrappedValue != nil },
            set: { isPresented in
                if !isPresented {
                    errorMessage.wrappedValue = nil
                }
            }
        )
    }
}
