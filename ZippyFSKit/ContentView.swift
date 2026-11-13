import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var choosing = false
    @State private var status = ""

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.zipper")
                .font(.system(size: 48))
            Text("Zippy")
                .font(.title)
            Button("ZIP mounten …") { choosing = true }
            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(40)
        .frame(minWidth: 360)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.zip]) { result in
            Task { await mount(result) }
        }
    }

    private func mount(_ result: Result<URL, Error>) async {
        do {
            let zip = try result.get()
            try await ArchiveMounter.mount(zip: zip)
            status = "An DiskImageMounter übergeben: \(zip.lastPathComponent)"
        } catch {
            status = "Fehler: \(error.localizedDescription)"
        }
    }
}
