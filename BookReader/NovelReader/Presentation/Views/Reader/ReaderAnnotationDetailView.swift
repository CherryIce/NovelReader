import SwiftUI

struct ReaderAnnotationDetailView: View {
    @ObservedObject var viewModel: ReaderViewModel
    let annotationKey: ReaderAnnotationKey

    @Environment(\.dismiss) private var dismiss
    @State private var editorContext: ThoughtEditorContext?
    @State private var thoughtPendingDeletion: Bookmark?
    @State private var showDeleteConfirmation = false

    var body: some View {
        Group {
            if let annotation = viewModel.annotationGroup(for: annotationKey) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        sourceSection(annotation)
                        thoughtsSection(annotation)
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 42))
                        .foregroundColor(.secondary)
                    Text("这段划线已被删除")
                        .font(.headline)
                    Button("返回") { dismiss() }
                }
            }
        }
        .navigationTitle("划线详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("完成") { dismiss() }
            }
        }
        .sheet(item: $editorContext) { context in
            ReaderThoughtEditor(
                title: context.thought == nil ? "添加想法" : "编辑想法",
                initialText: context.thought?.note ?? "",
                isSaving: viewModel.isSavingAnnotationThought,
                onSave: { text in
                    if let thought = context.thought {
                        viewModel.updateThought(thought, text: text)
                    } else {
                        viewModel.addThought(to: annotationKey, text: text)
                    }
                }
            )
        }
        .confirmationDialog(
            "删除这条想法？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("取消", role: .cancel) {
                thoughtPendingDeletion = nil
            }
            Button("删除", role: .destructive) {
                if let thought = thoughtPendingDeletion {
                    viewModel.deleteThought(thought)
                }
                thoughtPendingDeletion = nil
            }
        } message: {
            Text("删除后无法恢复，但不会删除这段划线。")
        }
        .alert(item: $viewModel.bookmarkAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("确定"))
            )
        }
    }

    private func sourceSection(_ annotation: ReaderAnnotationGroup) -> some View {
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
    }

    private func thoughtsSection(_ annotation: ReaderAnnotationGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("我的想法")
                    .font(.headline)
                Spacer()
                Text("\(annotation.thoughts.count)/\(ReaderAnnotationGroup.maximumThoughtCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if annotation.thoughts.isEmpty {
                Text("还没有想法，可以记录此刻的感受。")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(annotation.thoughts) { thought in
                    thoughtCard(thought)
                }
            }

            Button {
                editorContext = ThoughtEditorContext(thought: nil)
            } label: {
                Label(
                    annotation.canAddThought ? "添加想法" : "已达到 5 条上限",
                    systemImage: annotation.canAddThought ? "plus.bubble" : "checkmark.circle"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!annotation.canAddThought || viewModel.isSavingAnnotationThought)
        }
    }

    private func thoughtCard(_ thought: Bookmark) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(thought.note ?? "")
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text(formatDate(thought.updatedAt))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("编辑") {
                    editorContext = ThoughtEditorContext(thought: thought)
                }
                .font(.caption)
                .disabled(viewModel.isSavingAnnotationThought)

                Button("删除", role: .destructive) {
                    thoughtPendingDeletion = thought
                    showDeleteConfirmation = true
                }
                .font(.caption)
                .disabled(viewModel.isSavingAnnotationThought)
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

private struct ThoughtEditorContext: Identifiable {
    let id = UUID()
    let thought: Bookmark?
}

private struct ReaderThoughtEditor: View {
    let title: String
    let initialText: String
    let isSaving: Bool
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(
        title: String,
        initialText: String,
        isSaving: Bool,
        onSave: @escaping (String) -> Void
    ) {
        self.title = title
        self.initialText = initialText
        self.isSaving = isSaving
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        NavigationView {
            TextEditor(text: $text)
                .padding()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(!canSave)
                    }
                }
        }
        .interactiveDismissDisabled(isSaving)
    }
}
