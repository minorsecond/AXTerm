import Foundation

/// The CI-V commands the modem uses, as one table of typed builders, so a
/// golden-byte test covers every frame the app can send.
///
/// Addresses default to the IC-705 (`A4`) and the conventional controller
/// (`E0`); every builder takes them so another Icom works the same way.
nonisolated enum CIVCommand {

    static let ic705: UInt8 = 0xA4

    /// How many bytes after the command byte are a subcommand, per command.
    /// CI-V has no in-band marker; this is the reference guide's table.
    static func subcommandLength(_ command: UInt8) -> Int {
        switch command {
        case 0x07, 0x0E, 0x0F, 0x13, 0x14, 0x15, 0x16, 0x19, 0x1A, 0x1B, 0x1C, 0x1E, 0x21, 0x25, 0x26, 0x27:
            return 1
        default:
            return 0
        }
    }

    private static func frame(_ radio: UInt8, _ controller: UInt8, _ command: UInt8,
                              _ sub: UInt8? = nil, _ data: [UInt8] = []) -> CIVFrame {
        CIVFrame(to: radio, from: controller, command: command, subcommand: sub, data: data)
    }

    // MARK: - Identity

    /// `19 00` → the radio answers with its own address.
    static func identify(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x19, 0x00)
    }

    // MARK: - Frequency and mode

    static func readFrequency(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x03)
    }

    static func setFrequency(hz: Int, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x05, nil, CIVBCD.frequencyBytes(hz: hz))
    }

    static func readMode(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x04)
    }

    /// `06 <mode> [filter]`; no filter means FIL1.
    static func setMode(_ mode: RigMode, filter: UInt8? = nil,
                        radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x06, nil, [mode.rawValue] + (filter.map { [$0] } ?? []))
    }

    /// `1A 06 <on> <filter>` — data mode (FM-D, USB-D …).
    static func readDataMode(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x1A, 0x06)
    }

    static func setDataMode(_ on: Bool, filter: UInt8 = 1,
                            radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x1A, 0x06, on ? [0x01, filter] : [0x00, 0x00])
    }

    /// `1A 03 <bcd>` — IF filter width, in the reference guide's coding:
    /// 0…9 = 50…500 Hz in 50 Hz steps, 10…40 = 600…3600 Hz in 100 Hz steps.
    static func setIFWidth(hz: Int, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        let code: Int = hz <= 500 ? max(0, min(9, hz / 50 - 1)) : max(10, min(40, (hz - 600) / 100 + 10))
        return frame(radio, controller, 0x1A, 0x03, [UInt8((code / 10) << 4 | code % 10)])
    }

    // MARK: - Transmit

    static func setPTT(_ on: Bool, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x1C, 0x00, [on ? 0x01 : 0x00])
    }

    static func readPTT(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x1C, 0x00)
    }

    // MARK: - Meters

    static func readSquelchStatus(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x15, 0x01)
    }

    static func readSMeter(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x15, 0x02)
    }

    // MARK: - Set-mode menu items (`1A 05 <item> <data>`)

    enum MenuItem: Int {
        case txDelayHF = 38, txDelay50M = 39, txDelay144M = 41, txDelay430M = 42
        case usbAFOutputSelect = 109, usbAFOutputLevel = 110, usbAFSquelch = 111
        case usbModLevel = 116, dataOffMod = 118, dataMod = 119
        case usbSend = 125, usbKeyingCW = 126, usbKeyingRTTY = 127
        case civTransceive = 131, civUSBEchoBack = 132, usbBFunction = 133
    }

    static func setMenuItem(_ item: MenuItem, _ data: [UInt8],
                            radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x1A, 0x05, CIVBCD.item(item.rawValue) + data)
    }

    static func readMenuItem(_ item: MenuItem, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        frame(radio, controller, 0x1A, 0x05, CIVBCD.item(item.rawValue))
    }

    static func setTransceive(_ on: Bool, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        setMenuItem(.civTransceive, [on ? 0x01 : 0x00], radio: radio, controller: controller)
    }

    static func setEchoBack(_ on: Bool, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        setMenuItem(.civUSBEchoBack, [on ? 0x01 : 0x00], radio: radio, controller: controller)
    }

    /// `00` off — PTT by command, not by the serial lines.
    static func setUSBSendOff(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        setMenuItem(.usbSend, [0x00], radio: radio, controller: controller)
    }

    /// `00` = OFF (open): the modem hears everything and decides for itself.
    static func setAFSquelchOpen(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        setMenuItem(.usbAFSquelch, [0x00], radio: radio, controller: controller)
    }

    /// `01` = USB: modulate from the computer, not the microphone.
    static func setDataModUSB(radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        setMenuItem(.dataMod, [0x01], radio: radio, controller: controller)
    }

    static func setUSBModLevel(_ level: Int, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        setMenuItem(.usbModLevel, CIVBCD.meterBytes(level), radio: radio, controller: controller)
    }

    static func setAFOutputLevel(_ level: Int, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        setMenuItem(.usbAFOutputLevel, CIVBCD.meterBytes(level), radio: radio, controller: controller)
    }

    /// The radio's own TX Delay menus, off: the modem's TXDELAY is the budget.
    static func setTXDelayOff(_ item: MenuItem, radio: UInt8 = ic705, controller: UInt8 = CIVFrame.controller) -> CIVFrame {
        setMenuItem(item, [0x00], radio: radio, controller: controller)
    }
}
