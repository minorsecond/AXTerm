import Combine
import Foundation

/// The Mac's sound devices, for the sound modem's pickers, kept current as
/// devices come and go. The radio's USB codec appears as "USB Audio CODEC".
@MainActor
final class AudioDeviceDiscovery: ObservableObject {
    @Published private(set) var devices: [ModemAudioDevice] = []

    #if os(macOS)
    private var observer: CoreAudioDeviceCatalog.DeviceListObserver?
    #endif

    func startObserving() {
        refresh()
        #if os(macOS)
        guard observer == nil else { return }
        observer = CoreAudioDeviceCatalog.observeDeviceList { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        #endif
    }

    func stopObserving() {
        #if os(macOS)
        observer = nil
        #endif
    }

    func refresh() {
        #if os(macOS)
        devices = CoreAudioDeviceCatalog.devices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        #else
        devices = []
        #endif
    }

    var inputs: [ModemAudioDevice] { devices.filter(\.hasInput) }
    var outputs: [ModemAudioDevice] { devices.filter(\.hasOutput) }
}
