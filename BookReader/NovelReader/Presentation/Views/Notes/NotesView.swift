import SwiftUI
import UIKit

struct NotesView: View {
    @StateObject private var viewModel = NotesViewModel()

    var body: some View {
        NavigationView {
            ZStack {
                Color(.secondarySystemBackground).ignoresSafeArea()
                content
            }
            .navigationTitle("笔记")
            .searchable(text: $viewModel.searchText, prompt: "搜索书名或笔记内容")
            .onAppear { viewModel.loadNotes() }
            .refreshable { viewModel.loadNotes() }
            .alert("笔记加载失败", isPresented: errorBinding) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "请稍后重试")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.summaries.isEmpty {
            ProgressView("正在整理笔记…")
        } else if viewModel.summaries.isEmpty {
            emptyView
        } else if viewModel.filteredSummaries.isEmpty {
            emptySearchView
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    summaryHeader
                    ForEach(viewModel.filteredSummaries) { summary in
                        NavigationLink(destination: BookNotesView(book: summary.book)) {
                            BookNoteCard(summary: summary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
        }
    }

    private var summaryHeader: some View {
        HStack {
            Text("\(viewModel.totalAnnotationCount) 条笔记 · 来自 \(viewModel.summaries.count) 本书")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.top, 8)
    }

    private var emptyView: some View {
        VStack(spacing: 14) {
            Image(systemName: "note.text")
                .font(.system(size: 52))
                .foregroundColor(.secondary)
            Text("还没有笔记")
                .font(.headline)
            Text("在阅读页长按选择原文，即可添加划线或想法。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }

    private var emptySearchView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 42))
                .foregroundColor(.secondary)
            Text("没有匹配的笔记")
                .font(.headline)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct BookNoteCard: View {
    let summary: BookNoteSummary

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(summary.annotations.count)")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("条笔记")
                        .font(.body)
                }

                Text("《\(summary.book.title)》")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)

                Text(readingDescription)
                    .font(.subheadline)
                    .foregroundColor(Color(.tertiaryLabel))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NoteBookCover(book: summary.book, width: 68, height: 92)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .padding(18)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notes.book.\(summary.book.id.uuidString)")
    }

    private var readingDescription: String {
        switch summary.book.readingStatus {
        case .unread:
            return "未开始阅读"
        case .reading:
            return summary.book.lastReadAt.map { "在读 · \(Self.dateFormatter.string(from: $0))" }
                ?? "在读"
        case .completed:
            return "已读完"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()
}

struct BookNotesView: View {
    let book: Book
    @StateObject private var viewModel: BookNotesViewModel

    init(book: Book) {
        self.book = book
        _viewModel = StateObject(wrappedValue: BookNotesViewModel(book: book))
    }

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground).ignoresSafeArea()
            if viewModel.isLoading && viewModel.annotations.isEmpty {
                ProgressView("正在加载…")
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        bookHeader
                        if viewModel.annotations.isEmpty {
                            Text("这本书还没有笔记")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .padding(.top, 36)
                        } else {
                            ForEach(viewModel.annotations) { annotation in
                                NavigationLink(
                                    destination: NoteDetailView(
                                        book: book,
                                        annotation: annotation,
                                        chapterTitle: viewModel.chapterTitle(
                                            for: annotation.key.chapterIndex
                                        )
                                    )
                                ) {
                                    AnnotationCard(
                                        annotation: annotation,
                                        chapterTitle: viewModel.chapterTitle(
                                            for: annotation.key.chapterIndex
                                        )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle("笔记")
        .navigationBarTitleDisplayMode(.inline)
        .hidesRootTabBar()
        .onAppear { viewModel.loadNotes() }
        .alert("笔记加载失败", isPresented: errorBinding) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "请稍后重试")
        }
    }

    private var bookHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(book.title)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                Text("共 \(viewModel.annotations.count) 条笔记")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                if let author = book.author, !author.isEmpty {
                    Text(author)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NoteBookCover(book: book, width: 76, height: 104)
        }
        .padding(18)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )
    }
}

private struct AnnotationCard: View {
    let annotation: ReaderAnnotationGroup
    let chapterTitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "textformat")
                .font(.title3)
                .foregroundColor(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 8) {
                Text(chapterTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text(annotation.selectedText.isEmpty ? "原文内容暂不可用" : annotation.selectedText)
                    .font(.body)
                    .lineLimit(4)
                if let thought = annotation.thoughts.last?.note, !thought.isEmpty {
                    Label(thought, systemImage: "bubble.left")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(Color(.tertiaryLabel))
                .padding(.top, 4)
        }
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct NoteDetailView: View {
    let book: Book
    let annotation: ReaderAnnotationGroup
    let chapterTitle: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title)
                        .font(.headline)
                    Text(chapterTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Label("划线原文", systemImage: "quote.opening")
                        .font(.headline)
                        .foregroundColor(.orange)
                    Text(annotation.selectedText.isEmpty ? "原文内容暂不可用" : annotation.selectedText)
                        .font(.body)
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("我的想法")
                            .font(.headline)
                        Spacer()
                        Text("\(annotation.thoughts.count) 条")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if annotation.thoughts.isEmpty {
                        Text("这是一条纯划线，暂时没有添加想法。")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(annotation.thoughts) { thought in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(thought.note ?? "")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(Self.dateFormatter.string(from: thought.updatedAt))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(14)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("笔记详情")
        .navigationBarTitleDisplayMode(.inline)
        .hidesRootTabBar()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private struct NoteBookCover: View {
    let book: Book
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.blue.opacity(0.12))
            if let path = book.coverImagePath, let image = UIImage(contentsOfFile: path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(book.title)
                    .font(.caption2.weight(.medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.08)))
    }
}
