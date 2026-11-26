import SwiftUI

@main
struct HDDMacSentinelApp: App {
    var body: some Scene {
        Window("HDD Mac Sentinel", id: "main") {
            DiskWindow()
        }
        .defaultSize(width: 860, height: 700)
    }
}

@MainActor
final class DiskModel: ObservableObject {
    struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let isError: Bool
    }

    @Published var disks: [ExternalDisk] = []
    @Published var selection: UInt64?
    @Published var scanError: String?
    @Published var isRefreshing = false
    @Published var hasScanned = false
    @Published var operation: String?
    @Published var notice: Notice?

    var selectedDisk: ExternalDisk? { disks.first { $0.id == selection } }

    func refresh() async {
        guard !isRefreshing, operation == nil else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            hasScanned = true
        }

        let result = await Task.detached(priority: .utility) {
            Result { try DiskService().scan() }
        }.value
        guard operation == nil else { return }

        switch result {
        case .success(let found):
            disks = found
            scanError = nil
            if selectedDisk == nil { selection = found.first?.id }
        case .failure(let error):
            disks = []
            scanError = error.localizedDescription
        }
    }

    func erase(_ request: EraseRequest) async {
        guard operation == nil else { return }
        operation = "Disk biçimlendiriliyor…"
        let result = await Task.detached(priority: .userInitiated) {
            Result { try DiskService().erase(request) }
        }.value
        switch result {
        case .success:
            notice = Notice(title: "Biçimlendirme tamamlandı",
                            detail: "“\(request.name)” diski \(request.format.label) biçiminde hazır.",
                            isError: false)
        case .failure(let error):
            notice = Notice(title: "Biçimlendirme tamamlanamadı",
                            detail: error.localizedDescription, isError: true)
        }
        operation = nil
        await refresh()
    }

    func verify(_ disk: ExternalDisk) async {
        guard operation == nil else { return }
        operation = "Bölüm haritası denetleniyor…"
        let result = await Task.detached(priority: .userInitiated) {
            Result { try DiskService().verify(disk) }
        }.value
        switch result {
        case .success(let output):
            notice = Notice(title: "Bölüm haritası denetimi tamamlandı",
                            detail: output.isEmpty ? "Bölüm haritasında sorun bildirilmedi." : output,
                            isError: false)
        case .failure(let error):
            notice = Notice(title: "Bölüm haritası denetlenemedi",
                            detail: error.localizedDescription, isError: true)
        }
        operation = nil
        await refresh()
    }

    func verifyFilesystems(_ disk: ExternalDisk) async {
        guard operation == nil else { return }
        operation = "Dosya sistemleri denetleniyor…"
        let result = await Task.detached(priority: .userInitiated) {
            Result { try DiskService().verifyFilesystems(disk) }
        }.value
        switch result {
        case .success(let checks):
            let issues = checks.filter { !$0.verified }.count
            let summary = "\(checks.count - issues)/\(checks.count) denetimde sorun bildirilmedi."
            let report = ([disk.name, summary] + checks.map(\.report)).joined(separator: "\n\n")
            notice = Notice(title: "Dosya sistemi denetimi", detail: report, isError: issues > 0)
        case .failure(let error):
            notice = Notice(title: "Dosya sistemleri denetlenemedi",
                            detail: error.localizedDescription, isError: true)
        }
        operation = nil
        await refresh()
    }
}

struct DiskWindow: View {
    @StateObject private var model = DiskModel()
    @State private var confirmation: EraseRequest?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 240, maxWidth: 290, maxHeight: .infinity)
            content
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, minHeight: 580)
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .sheet(item: $confirmation) { request in
            confirmationSheet(request)
        }
        .sheet(item: $model.notice) { notice in
            resultSheet(notice)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Harici diskler").font(.headline)
                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("Disk listesini yenile")
                .accessibilityLabel("Disk listesini yenile")
                .disabled(model.isRefreshing || model.operation != nil)
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(model.disks) { disk in
                        Button {
                            model.selection = disk.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "externaldrive")
                                    .font(.system(size: 16))
                                    .frame(width: 24)
                                    .foregroundStyle(model.selection == disk.id ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(disk.name).font(.callout.weight(.medium)).lineLimit(1)
                                    Text("\(disk.capacity) · \(disk.device)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(10)
                            .background {
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(model.selection == disk.id ? Color.accentColor.opacity(0.13) : .clear)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.selection == disk.id ? .isSelected : [])
                    }
                }
            }
            .disabled(model.operation != nil)
            if let operation = model.operation {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(operation).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(16)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        if let disk = model.selectedDisk {
            ScrollView {
                DiskDetail(disk: disk, isBusy: model.operation != nil) { request in
                    confirmation = request
                } verify: {
                    Task { await model.verify(disk) }
                } verifyFilesystems: {
                    Task { await model.verifyFilesystems(disk) }
                }
                .id(disk.id)
                .frame(maxWidth: 730)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        } else if let error = model.scanError {
            placeholder(icon: "exclamationmark.triangle", title: "Diskler okunamadı", message: error)
        } else if !model.hasScanned {
            ProgressView("Harici diskler aranıyor…")
        } else {
            placeholder(icon: "externaldrive.badge.plus", title: "Harici disk bağlı değil",
                        message: "Bir USB bellek, SSD veya sabit disk bağlayın. Disk listede otomatik olarak görünecek.")
        }
    }

    private func placeholder(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 39, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title).font(.title2.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 330)
        }
        .padding(24)
    }

    private func confirmationSheet(_ request: EraseRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Disk biçimlendirilsin mi?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.disk.name).font(.headline)
                Text(request.disk.subtitle).foregroundStyle(.secondary)
            }
            if !request.disk.volumes.isEmpty {
                Text(request.disk.volumes.joined(separator: ", "))
                    .foregroundStyle(.secondary)
            }
            Text("Bu diskteki tüm bölümler ve dosyalar silinecek.")
                .fontWeight(.semibold)
            Text("Yeni disk adı: \(request.name)  ·  \(request.format.label)")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Vazgeç") { confirmation = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Diski Sil ve Biçimlendir", role: .destructive) {
                    confirmation = nil
                    Task { await model.erase(request) }
                }
                .disabled(model.selectedDisk?.id != request.disk.id || model.operation != nil)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 470)
    }

    private func resultSheet(_ notice: DiskModel.Notice) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(notice.title, systemImage: notice.isError ? "exclamationmark.triangle" : "checkmark.circle")
                .font(.title2.bold())
                .foregroundStyle(notice.isError ? Color.red : .primary)
            ScrollView {
                Text(notice.detail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 65, idealHeight: 160, maxHeight: 260)
            HStack {
                Spacer()
                Button("Kapat") { model.notice = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

struct DiskDetail: View {
    let disk: ExternalDisk
    let isBusy: Bool
    let erase: (EraseRequest) -> Void
    let verify: () -> Void
    let verifyFilesystems: () -> Void

    @State private var name = "Harici Disk"
    @State private var format = DiskFormat.exFAT

    private var volumeName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var validation: String? { format.nameError(volumeName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 13) {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(disk.name).font(.title2.bold())
                    Text(disk.subtitle).foregroundStyle(.secondary)
                }
            }

            section("Disk sağlığı") {
                Label(disk.smart.title, systemImage: smartIcon)
                    .font(.headline)
                    .foregroundStyle(smartColor)
                Text(disk.smart.description).foregroundStyle(.secondary)
                if let used = disk.percentageUsed {
                    Text("Tahmini SSD ömrü tüketimi: %\(used)")
                        .font(.callout)
                }
                HStack {
                    Text("Birimlerde dosya sistemi hatalarını arar. Sonuç dosya sistemiyle sınırlıdır.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 10)
                    Button("Dosya Sistemlerini Denetle", action: verifyFilesystems)
                        .disabled(isBusy)
                }
                Divider().padding(.vertical, 2)
                detailRow("Bölüm haritası", disk.partitionMapLabel)
                if let media = disk.mediaType {
                    detailRow("Ortam", media)
                }
                if !disk.volumes.isEmpty {
                    detailRow("Birimler", disk.volumes.joined(separator: ", "))
                }
                HStack {
                    if !disk.isGUID {
                        Text("Denetim GUID bölüm haritası gerektirir.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Bölüm Haritasını Denetle", action: verify)
                        .disabled(isBusy || !disk.isGUID)
                }
            }

            section("Biçimlendir") {
                if disk.isStartupDisk || !disk.writable {
                    Text(disk.isStartupDisk ? "Bu disk macOS başlangıç diski olarak kullanılıyor." : "Disk yazmaya kapalı.")
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Yeni disk adı", text: $name, prompt: Text("Harici Disk"))
                    Picker("Dosya sistemi", selection: $format) {
                        ForEach(DiskFormat.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    Text(validation ?? format.hint)
                        .font(.caption)
                        .foregroundStyle(validation == nil ? Color.secondary : Color.red)
                    HStack {
                        Text("Bu işlem diskteki tüm dosyaları siler.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Diski Biçimlendir…") {
                            erase(EraseRequest(disk: disk, name: volumeName, format: format))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(validation != nil)
                    }
                    .padding(.top, 3)
                }
            }
            .disabled(isBusy)
        }
    }

    private var smartIcon: String {
        switch disk.smart {
        case .verified: "checkmark.circle.fill"
        case .failing: "exclamationmark.triangle.fill"
        case .unavailable, .unknown: "questionmark.circle"
        }
    }

    private var smartColor: Color {
        switch disk.smart {
        case .verified: .green
        case .failing: .red
        case .unavailable, .unknown: .secondary
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.callout)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1))
        }
    }
}
