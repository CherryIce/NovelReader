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
