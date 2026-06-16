import SwiftUI

enum PlaylistShowMode: Int, CaseIterable {
    case manual = 0
    case auto = 1
}

struct PlaylistPanel: View {
    @Bindable var model: VideoPlayerModel
    @Binding var mode: PlaylistShowMode

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            fileListView
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            Text(L10n.Playlist.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            Spacer()

            modeToggle
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var modeToggle: some View {
        HStack(spacing: 1) {
            modeButton(
                mode: .manual,
                icon: "hand.point.up.left.fill",
                help: L10n.Playlist.modeManualHelp.localized
            )
            modeButton(
                mode: .auto,
                icon: "cursorarrow.rays",
                help: L10n.Playlist.modeAutoHelp.localized
            )
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func modeButton(mode m: PlaylistShowMode, icon: String, help: String) -> some View {
        Button {
            mode = m
        } label: {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(mode == m ? .primary : .secondary)
                .frame(width: 28, height: 20)
                .contentShape(Rectangle())
                .background {
                    if mode == m {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.white.opacity(0.12))
                            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - File List

    private var fileListView: some View {
        Group {
            if model.directoryFiles.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(model.directoryFiles.enumerated()), id: \.offset) { index, url in
                                PlaylistRow(
                                    fileName: url.lastPathComponent,
                                    isCurrent: index == model.currentFileIndex,
                                    isPlaying: index == model.currentFileIndex && model.isPlaying
                                )
                                .id(index)
                                .onTapGesture(count: 2) {
                                    model.openFile(at: index)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .onAppear {
                        if model.currentFileIndex >= 0 {
                            proxy.scrollTo(model.currentFileIndex, anchor: .center)
                        }
                    }
                    .onChange(of: model.currentFileIndex) { _, newIndex in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.25))
            Text(L10n.Playlist.emptyTitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
            Text(L10n.Playlist.emptySubtitle)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.25))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }
}

// MARK: - Playlist Row

struct PlaylistRow: View {
    let fileName: String
    let isCurrent: Bool
    let isPlaying: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            if isCurrent {
                Image(systemName: isPlaying ? "speaker.wave.2.fill" : "play.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 14)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 14)
            }

            Text(fileName)
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .white : Color.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        }
        .padding(.horizontal, 8)
        .help(fileName)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var rowBackground: some ShapeStyle {
        if isCurrent {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        } else if isHovered {
            return AnyShapeStyle(Color.white.opacity(0.06))
        } else {
            return AnyShapeStyle(Color.clear)
        }
    }
}

#Preview {
    PlaylistPanel(
        model: VideoPlayerModel(),
        mode: .constant(.manual)
    )
    .frame(width: 260, height: 500)
}
