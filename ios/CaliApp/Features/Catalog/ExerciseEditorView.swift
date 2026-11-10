import CaliDomain
import SwiftUI
import UniformTypeIdentifiers
import PhotosUI

struct ExerciseEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Exercise
    @State private var posterLink: String
    @State private var videoLink: String
    @State private var importing = false
    @State private var importingVideo = false
    @State private var busy = false
    @State private var error: String?
    @State private var imported: [ExerciseMediaReference] = []
    @State private var saved = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var videoSelection: PhotosPickerItem?
    private let isNew: Bool

    init(exercise: Exercise? = nil) {
        isNew = exercise == nil
        let item = exercise ?? Exercise(id: UUID(), slug: UUID().uuidString.lowercased(), name: "",
            type: .reps, level: .beginner, equipment: [], muscles: [], cues: [], mistakes: [],
            catalogVersion: MockData.catalogVersion, symbol: "figure.strengthtraining.functional", paletteIndex: 0)
        _draft = State(initialValue: item)
        _posterLink = State(initialValue: item.poster?.source == .remote ? item.poster!.value : "")
        _videoLink = State(initialValue: item.video?.source == .remote ? item.video!.value : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Thông tin bài tập") {
                    TextField("Tên bài tập", text: $draft.name)
                    Picker("Kiểu tập", selection: $draft.type) {
                        ForEach(ExerciseType.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Cấp độ", selection: $draft.level) {
                        ForEach(ExerciseLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Nhóm cơ (mỗi dòng một mục)", text: lines($draft.muscles), axis: .vertical)
                    TextField("Dụng cụ (mỗi dòng một mục)", text: lines($draft.equipment), axis: .vertical)
                    TextField("Điểm cần nhớ (mỗi dòng một mục)", text: lines($draft.cues), axis: .vertical)
                    TextField("Lỗi thường gặp (mỗi dòng một mục)", text: lines($draft.mistakes), axis: .vertical)
                }
                Section("Ảnh bài tập") {
                    HStack(spacing: Spacing.m) {
                        PosterThumb(exercise: draft, size: 96)
                        Text(draft.poster == nil ? "Chưa có ảnh. Bài tập luôn cần ảnh để nhận diện." : "Ảnh đã chọn.")
                            .font(.footnote)
                            .foregroundStyle(Color.caliSecondary)
                    }
                    TextField("Link ảnh HTTPS", text: $posterLink).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Chọn ảnh từ Tệp") { importingVideo = false; importing = true }
                    PhotosPicker("Chọn ảnh từ Thư viện", selection: $photoSelection, matching: .images)
                    if draft.poster?.source == .local { Label("Đã chọn ảnh trên máy", systemImage: "checkmark.circle") }
                    Button("Gỡ ảnh", role: .destructive) { draft.poster = nil; posterLink = "" }
                }
                Section("Video hướng dẫn") {
                    TextField("Link video HTTPS", text: $videoLink).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Chọn video từ Tệp") { importingVideo = true; importing = true }
                    PhotosPicker("Chọn video từ Thư viện", selection: $videoSelection, matching: .videos)
                    if draft.video?.source == .local { Label("Đã chọn video trên máy", systemImage: "checkmark.circle") }
                    Button("Gỡ video", role: .destructive) { draft.video = nil; videoLink = "" }
                    Text("Ảnh tối đa 20 MB, video tối đa 200 MB. Tệp được sao chép vào app để dùng offline. Link cần mạng; link trang video có thể mở bằng trình duyệt.")
                        .font(.footnote)
                }
                if busy { ProgressView("Đang nhập tệp…") }
                if let error { Text(error).foregroundStyle(Color.caliError) }
            }
            .scrollContentBackground(.hidden)
            .background(COAMIScreenBackground())
            .navigationTitle(isNew ? "Bài tập mới" : "Sửa bài tập")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(busy)
            .onChange(of: photoSelection) { _, item in loadSelection(item, isVideo: false) }
            .onChange(of: videoSelection) { _, item in loadSelection(item, isVideo: true) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Lưu", action: save).disabled(busy || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: importingVideo ? [.movie] : [.image]) { result in
                switch result {
                case .failure: error = "Không mở được tệp. Hãy thử chọn lại."
                case .success(let url):
                    busy = true
                    let video = importingVideo
                    Task {
                        do {
                            let reference = try await Task.detached { try LocalMedia.importFile(url, isVideo: video) }.value
                            imported.append(reference)
                            if video { draft.video = reference; videoLink = "" }
                            else { draft.poster = reference; posterLink = "" }
                            error = nil
                        } catch { self.error = "Không nhập được tệp. Chọn đúng ảnh/video và kiểm tra giới hạn dung lượng." }
                        busy = false
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onDisappear {
            for item in imported where !saved || (item != draft.poster && item != draft.video) { LocalMedia.discard(item) }
        }
    }

    private func save() {
        var copy = draft
        for (text, video) in [(posterLink, false), (videoLink, true)] {
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let ref = ExerciseMediaReference.remote(text) else { error = "Hãy nhập link HTTPS hợp lệ."; return }
                if video { copy.video = ref } else { copy.poster = ref }
            } else if video && copy.video?.source == .remote { copy.video = nil }
            else if !video && copy.poster?.source == .remote { copy.poster = nil }
        }
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.saveExercise(copy) { draft = copy; saved = true; dismiss() }
        else { error = store.alertMessage; store.alertMessage = nil }
    }

    private func loadSelection(_ item: PhotosPickerItem?, isVideo: Bool) {
        guard let item else { return }
        busy = true
        Task {
            do {
                let reference: ExerciseMediaReference?
                if isVideo { reference = try await item.loadTransferable(type: ImportedVideo.self)?.reference }
                else { reference = try await item.loadTransferable(type: ImportedPhoto.self)?.reference }
                guard let reference else { throw CocoaError(.fileReadCorruptFile) }
                imported.append(reference)
                if isVideo { draft.video = reference; videoLink = "" }
                else { draft.poster = reference; posterLink = "" }
                error = nil
            } catch { self.error = "Không nhập được ảnh/video. Kiểm tra dung lượng hoặc tải bản gốc từ iCloud rồi thử lại." }
            if isVideo { videoSelection = nil } else { photoSelection = nil }
            busy = false
        }
    }

    private func lines(_ binding: Binding<[String]>) -> Binding<String> {
        Binding(get: { binding.wrappedValue.joined(separator: "\n") }, set: { binding.wrappedValue = $0.components(separatedBy: "\n") })
    }
}
