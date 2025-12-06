//
//  HomeView.swift
//  Soramoyou
//
//  Created on 2025-12-06.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationView {
            Text("ホーム画面")
                .navigationTitle("そらもよう")
        }
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
}

