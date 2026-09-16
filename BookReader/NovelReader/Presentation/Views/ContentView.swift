import SwiftUI
import Foundation

struct ContentView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage(AppAppearance.storageKey) private var appAppearance = AppAppearance.system.rawValue

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                MainTabView()
                    .transition(.opacity)
            } else {
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        hasCompletedOnboarding = true
                    }
                }
                .transition(.opacity)
            }
        }
        .preferredColorScheme(
            AppAppearance(rawValue: appAppearance)?.colorScheme
        )
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            LibraryView()
                .showsRootTabBar()
                .tabItem {
                    HStack {
                        Image(systemName: "books.vertical")
                        Text("书架")
                    }
                }
            
            NotesView()
                .showsRootTabBar()
                .tabItem {
                    HStack {
                        Image(systemName: "note.text")
                        Text("笔记")
                    }
                }

            ReadingStatsView()
                .showsRootTabBar()
                .tabItem {
                    HStack {
                        Image(systemName: "chart.bar.fill")
                        Text("统计")
                    }
                }
            
            AppSettingsView()
                .showsRootTabBar()
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
