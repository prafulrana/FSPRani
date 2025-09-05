import SwiftUI

struct ContentView: View {
    var body: some View {
        BallTrackerView()
            .edgesIgnoringSafeArea(.all)
            .statusBar(hidden: true)
    }
}

struct BallTrackerView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> BallTrackerViewController {
        return BallTrackerViewController()
    }
    
    func updateUIViewController(_ uiViewController: BallTrackerViewController, context: Context) {
    }
}