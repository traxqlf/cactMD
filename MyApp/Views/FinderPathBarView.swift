import AppKit
import SwiftUI

/// Finder-style path bar pinned at the bottom of the glass bubble.
/// Every segment jumps straight back to that folder.
struct FinderPathBarView: View {
    let rootURL: URL
    let currentURL: URL
    let onNavigate: (URL) -> Void

    private struct Segment: Identifiable {
        let url: URL
        let name: String
        var id: URL { url }
    }

    private var segments: [Segment] {
        let rootComponents = rootURL.pathComponents
        let currentComponents = currentURL.pathComponents
        guard currentComponents.starts(with: rootComponents),
              currentComponents.count >= rootComponents.count else {
            return [Segment(url: rootURL, name: rootURL.lastPathComponent)]
        }

        var result: [Segment] = []
        var cursor = rootURL
        result.append(Segment(url: cursor, name: rootURL.lastPathComponent))

        for component in currentComponents.dropFirst(rootComponents.count) {
            cursor = cursor.appendingPathComponent(component, isDirectory: true)
            result.append(Segment(url: cursor, name: component))
        }
        return result
    }

    /// Soft fade on both edges so segments slide under the glass instead of
    /// being cut off.
    private var edgeFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.04),
                .init(color: .black, location: 0.96),
                .init(color: .clear, location: 1)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                        let isCurrent = index == segments.count - 1

                        PathSegmentView(
                            name: segment.name,
                            url: segment.url,
                            isCurrent: isCurrent,
                            action: { onNavigate(segment.url) }
                        )
                        .id(segment.id)

                        if !isCurrent {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            .mask(edgeFade)
            .onAppear {
                if let last = segments.last {
                    proxy.scrollTo(last.id, anchor: .trailing)
                }
            }
            .onChange(of: currentURL) { _, _ in
                if let last = segments.last {
                    proxy.scrollTo(last.id, anchor: .trailing)
                }
            }
        }
        .frame(height: 26)
        .onAppear {
            FileIconProvider.shared.prefetchDirectoryURLs(segments.map(\.url))
        }
        .onChange(of: currentURL) { _, _ in
            FileIconProvider.shared.prefetchDirectoryURLs(segments.map(\.url))
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 0.75)
                .padding(.horizontal, 10)
        }
    }
}

private struct PathSegmentView: View {
    let name: String
    let url: URL
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(nsImage: FileIconProvider.shared.icon(for: url, isDirectory: true))
                    .resizable()
                    .frame(width: 12, height: 12)

                Text(name)
                    .font(.system(size: 10.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.primary.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.13 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .help(url.path)
    }
}
