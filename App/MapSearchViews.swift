import SwiftUI

struct MapSearchField: View {
    @ObservedObject var search: MapSearchModel
    var focus: FocusState<Bool>.Binding
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索地点或坐标", text: $search.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(focus)
                .onSubmit(onSubmit)
                .accessibilityLabel("搜索地点、坐标或地图链接")
                .accessibilityIdentifier("mapSearch.input")
                .frame(minWidth: 0, maxWidth: .infinity)
            if !search.text.isEmpty || search.isSearching {
                Button {
                    Haptics.light()
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(HomeInteractiveButtonStyle())
                .accessibilityLabel(search.isSearching ? "取消搜索并清除输入" : "清除搜索")
                .accessibilityIdentifier("mapSearch.clear")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .frame(minHeight: 46)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityAction(named: "搜索") { onSubmit() }
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
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text("正在搜索…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                }
                if !search.error.isEmpty {
                    Text(search.error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                ForEach(search.results) { result in
                    resultRow(result)
                    if result.id != search.results.last?.id {
                        Divider().padding(.horizontal, 10).opacity(0.4)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
        .accessibilityIdentifier("mapSearch.results")
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.control, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }

    private func resultRow(_ result: SearchLocationResult) -> some View {
        HStack(spacing: 8) {
            Button {
                Haptics.selection()
                onSelect(result)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 16))
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择\(result.name)，\(result.subtitle)")

            HStack(spacing: 4) {
                resultMiniAction("doc.on.doc", label: "复制\(result.name)的坐标") {
                    Haptics.light()
                    onCopy(result)
                }
                resultMiniAction("star", label: "收藏\(result.name)") {
                    Haptics.light()
                    onSave(result)
                }
                resultMiniAction("trash", label: "从搜索结果移除\(result.name)", tint: .red) {
                    Haptics.light()
                    search.remove(result)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .frame(minHeight: 46)
    }

    private func resultMiniAction(
        _ symbol: String,
        label: String,
        tint: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(HomeInteractiveButtonStyle())
        .accessibilityLabel(label)
    }
}
