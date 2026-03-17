//
//  ImageShareSheet.swift
//  Soramoyou
//
//  UIActivityViewController を SwiftUI でラップした共有シート

import SwiftUI

struct ImageShareSheet: UIViewControllerRepresentable {
    let images: [UIImage]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: images, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
