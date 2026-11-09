//
//  CoverPicker.swift
//  Lotion
//
//  The popover for choosing a note's cover: the wallpapers macOS ships,
//  Unsplash (its Wallpapers topic until the user searches), or an image from
//  disk. Choosing applies at once; the popover stays open to try another.
//

import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Results outlive the popover, so reopening it costs no requests.
@MainActor
@Observable
final class UnsplashBrowser {
    static let shared = UnsplashBrowser()

    var query = ""
    private(set) var photos: [UnsplashPhoto] = []
    private(set) var hasMore = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var downloadingID: String?
    private var loadedQuery: String?
    private var page = 0
    private var loadTask: Task<Void, Never>?

    var hasKey: Bool { UnsplashClient.accessKey != nil }

    func loadIfNeeded() {
        guard hasKey, loadedQuery == nil, !isLoading else { return }
        submit()
    }

    func submit() {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasKey, query != loadedQuery || errorMessage != nil else { return }
        loadTask?.cancel()
        loadedQuery = query
        photos = []
        page = 0
        load()
    }

    func loadMore() {
        guard hasMore, !isLoading else { return }
        load()
    }

    private func load() {
        let query = loadedQuery ?? ""
        let nextPage = page + 1
        isLoading = true
        errorMessage = nil
        loadTask = Task {
            do {
                let result = try await UnsplashClient.photos(query: query, page: nextPage)
                guard !Task.isCancelled else { return }
                let known = Set(photos.map(\.id))
                photos += result.photos.filter { !known.contains($0.id) }
                hasMore = result.hasMore
                page = nextPage
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                loadedQuery = nil
            }
            isLoading = false
        }
    }
}

struct CoverPicker: View {
    let note: Note
    let library: Library

    enum Source: String, CaseIterable { case gallery = "Gallery", unsplash = "Unsplash", upload = "Upload" }
    @AppStorage("coverPickerSource") private var source: Source = .gallery
    @State private var browser = UnsplashBrowser.shared

    private let columns = Array(repeating: GridItem(.flexible(), spacing: Space.m, alignment: .top), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack {
                Picker("Source", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if library.cover(for: note) != nil {
                    Button("Remove") { library.setCover(nil, for: note) }
                }
            }
            switch source {
            case .gallery: gallery
            case .unsplash: unsplash
            case .upload: upload
            }
        }
        .padding(Space.xl)
        .frame(width: 460, height: 400, alignment: .top)
    }

    // MARK: Gallery

    private var gallery: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Space.m) {
                ForEach(SystemWallpapers.all) { wallpaper in
                    Tile(isSelected: library.cover(for: note)?.file == wallpaper.url.path, help: wallpaper.name) {
                        ThumbnailImage(url: wallpaper.thumbnail)
                    } action: {
                        library.setCover(NoteCover(file: wallpaper.url.path), for: note)
                    }
                }
            }
        }
    }

    // MARK: Unsplash

    @ViewBuilder private var unsplash: some View {
        if !browser.hasKey {
            Text("This build has no Unsplash Access Key.")
                .font(.dsCallout)
                .foregroundStyle(Palette.secondaryLabel)
        } else {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.s) {
                    TextField("Search Unsplash", text: $browser.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { browser.submit() }
                    if browser.isLoading { ProgressView().controlSize(.small) }
                }
                if let error = browser.errorMessage {
                    Text(error).font(.dsCaption).foregroundStyle(.red)
                }
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Space.m) {
                        ForEach(browser.photos) { photo in
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Tile(isSelected: false, help: "Photo by \(photo.user.name) on Unsplash") {
                                    AsyncImage(url: photo.urls.small) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.primary.opacity(0.06)
                                    }
                                    .overlay {
                                        if browser.downloadingID == photo.id {
                                            Color.black.opacity(0.3)
                                            ProgressView().controlSize(.small)
                                        }
                                    }
                                } action: {
                                    choose(photo)
                                }
                                Link(photo.user.name, destination: photo.photographerURL)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Palette.secondaryLabel)
                                    .lineLimit(1)
                            }
                        }
                    }
                    if browser.hasMore {
                        Button(browser.isLoading ? "Loading…" : "Show More") { browser.loadMore() }
                            .disabled(browser.isLoading)
                            .padding(.top, Space.s)
                    }
                }
                Link("Photos from Unsplash", destination: UnsplashClient.unsplashURL)
                    .font(.dsCaption)
                    .foregroundStyle(Palette.secondaryLabel)
            }
            .onAppear { browser.loadIfNeeded() }
        }
    }

    private func choose(_ photo: UnsplashPhoto) {
        guard browser.downloadingID == nil else { return }
        browser.downloadingID = photo.id
        Task {
            await library.setUnsplashCover(photo, for: note)
            browser.downloadingID = nil
        }
    }

    // MARK: Upload

    private var upload: some View {
        VStack(spacing: Space.l) {
            Button("Choose an Image…") { chooseFile() }
                .controlSize(.large)
            Text("Images up to any size; a copy is kept with your notes.")
                .font(.dsCaption)
                .foregroundStyle(Palette.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.importCover(from: url, for: note)
    }
}

/// A grid cell: a 16:10 image that applies on click.
private struct Tile<Content: View>: View {
    let isSelected: Bool
    let help: String
    @ViewBuilder let content: Content
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Color.clear
                .aspectRatio(1.6, contentMode: .fit)
                .overlay { content }
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Palette.hairline, lineWidth: isSelected ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// A small local image, decoded off the main thread.
private struct ThumbnailImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Color.primary.opacity(0.06)
            }
        }
        .task(id: url) {
            image = CoverImages.cached(url, maxPixels: 400)
            if image == nil {
                CoverImages.load(url, maxPixels: 400) { image = $0 }
            }
        }
    }
}
