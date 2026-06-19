import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    HStack {
                        Image(systemName: "books.vertical")
                        Text("书架")
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .wifiTransferDidFinish)) { _ in
                    // WiFi 传书结束后，LibraryView 的 onAppear 会自动刷新
                }
            
            ReadingStatsView()
                .tabItem {
                    HStack {
                        Image(systemName: "chart.bar.fill")
                        Text("统计")
                    }
                }
            
            Text("设置")
                .tabItem {
                    HStack {
                        Image(systemName: "gear")
                        Text("设置")
                    }
                }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
