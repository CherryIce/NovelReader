import SwiftUI

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var selectedPage = 0

    private let pages = OnboardingPage.all

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.onboardingInk, .onboardingTeal],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button("跳过", action: onComplete)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.onboardingPaper.opacity(0.85))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .opacity(selectedPage == pages.count - 1 ? 0 : 1)
                        .disabled(selectedPage == pages.count - 1)
                        .accessibilityIdentifier("onboardingSkipButton")
                }

                TabView(selection: $selectedPage) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                        OnboardingPageView(page: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))

                VStack(spacing: 24) {
                    HStack(spacing: 8) {
                        ForEach(pages.indices, id: \.self) { index in
                            Capsule()
                                .fill(
                                    index == selectedPage
                                        ? Color.onboardingAmber
                                        : Color.onboardingPaper.opacity(0.28)
                                )
                                .frame(width: index == selectedPage ? 24 : 8, height: 8)
                                .animation(.easeInOut(duration: 0.2), value: selectedPage)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("第 \(selectedPage + 1) 页，共 \(pages.count) 页")

                    Button(action: advance) {
                        HStack(spacing: 8) {
                            Text(selectedPage == pages.count - 1 ? "开始阅读" : "继续")
                                .font(.headline)
                            Image(systemName: selectedPage == pages.count - 1 ? "book.fill" : "arrow.right")
                        }
                        .foregroundColor(.onboardingInk)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(Color.onboardingPaper)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboardingPrimaryButton")
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func advance() {
        if selectedPage == pages.count - 1 {
            onComplete()
        } else {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedPage += 1
            }
        }
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 18) {
                    Image(page.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            maxWidth: min(proxy.size.width - 48, 420),
                            maxHeight: min(proxy.size.height * 0.55, 440)
                        )
                        .accessibilityHidden(true)

                    VStack(spacing: 12) {
                        Text(page.title)
                            .font(.system(.title, design: .rounded).weight(.bold))
                            .foregroundColor(.onboardingPaper)
                            .multilineTextAlignment(.center)

                        Text(page.detail)
                            .font(.body)
                            .foregroundColor(.onboardingPaper.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: 520)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height, alignment: .center)
                .padding(.horizontal, 24)
            }
        }
    }
}

private struct OnboardingPage {
    let imageName: String
    let title: String
    let detail: String

    static let all = [
        OnboardingPage(
            imageName: "OnboardingLibrary",
            title: "把喜欢的书带在身边",
            detail: "从 TXT、EPUB、PDF 或 WiFi 轻松导入，建立你的私人书架。"
        ),
        OnboardingPage(
            imageName: "OnboardingReading",
            title: "让阅读适合每一刻",
            detail: "日间、夜间、羊皮纸与护眼主题，字号和行距都由你掌控。"
        ),
        OnboardingPage(
            imageName: "OnboardingCompanion",
            title: "读、听、记，都在这里",
            detail: "听书、书签和阅读统计，让每一段阅读旅程都有迹可循。"
        )
    ]
}

private extension Color {
    static let onboardingInk = Color(red: 16 / 255, green: 27 / 255, blue: 45 / 255)
    static let onboardingTeal = Color(red: 22 / 255, green: 73 / 255, blue: 77 / 255)
    static let onboardingPaper = Color(red: 245 / 255, green: 232 / 255, blue: 203 / 255)
    static let onboardingAmber = Color(red: 215 / 255, green: 168 / 255, blue: 92 / 255)
}

struct OnboardingView_Previews: PreviewProvider {
    static var previews: some View {
        OnboardingView(onComplete: {})
    }
}
