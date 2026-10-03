import SwiftUI

struct MapSearchField: View {
    @ObservedObject var search: MapSearchModel
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("搜索地点、坐标或地图链接", text: $search.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(focus)
                .onSubmit(onSubmit)
                .accessibilityLabel("搜索地点、坐标或地图链接")
                .accessibilityIdentifier("mapSearch.input")
            Button { search.clear() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(search.text.isEmpty && !search.isSearching)
            .accessibilityLabel(search.isSearching ? "取消搜索并清除输入" : "清除搜索")
            .accessibilityIdentifier("mapSearch.clear")
            Button(action: onSubmit) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 20))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(search.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("提交搜索")
            .accessibilityIdentifier("mapSearch.submit")
        }
        .padding(.leading, 14)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .frame(minHeight: 48)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .shadow(color: .black.opacity(0.13), radius: 9, y: 4)
    }
}

struct MapSearchResults: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var search: MapSearchModel
    let onSelect: (SearchLocationResult) -> Void
    let onCopy: (SearchLocationResult) -> Void
    let onSave: (SearchLocationResult) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if search.isSearching {
                    HStack {
                        ProgressView().accessibilityHidden(true)
                        Text("正在搜索…").font(.subheadline)
                        Spacer()
                    }
                    .padding(12)
                    .accessibilityElement(children: .combine)
                }
                if !search.error.isEmpty {
                    Text(search.error).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                ForEach(search.results) { result in
                    resultRow(result)
                    if result.id != search.results.last?.id { Divider().padding(.horizontal, 12) }
                }
            }
        }
        .accessibilityIdentifier("mapSearch.results")
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
    }

    private func resultRow(_ result: SearchLocationResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { onSelect(result) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 20)).foregroundStyle(.red).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.name).font(.subheadline.weight(.semibold))
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        if !result.subtitle.isEmpty {
                            // 坐标标准也在此处，必须在材质背景与离屏渲染中保持清晰。
                            Text(result.subtitle).font(.caption)
                                .foregroundColor(Color(uiColor: .label))
                                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择\(result.name)，\(result.subtitle)")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                resultAction("doc.on.doc", label: "复制\(result.name)的坐标") { onCopy(result) }
                resultAction("star", label: "收藏\(result.name)") { onSave(result) }
                resultAction("trash", label: "从搜索结果移除\(result.name)") { search.remove(result) }
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func resultAction(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
