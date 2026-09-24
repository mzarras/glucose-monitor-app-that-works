// The system share sheet for a file the app wrote (CSV export, diagnostics; HANDOFF §4.5, §11
// step 6). `ShareLink` needs the URL before the user taps, but exports are written on demand, so
// the sheet is presented once the file exists.

import SwiftUI
import UIKit

struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
