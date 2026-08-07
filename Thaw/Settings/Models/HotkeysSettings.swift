//
//  HotkeysSettings.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Model for the app's Hotkeys settings.
@MainActor
@Observable
final class HotkeysSettings {
    @ObservationIgnored
    private let diagLog = DiagLog(category: "HotkeysSettings")
    /// The app's hotkey registry.
    let registry = HotkeyRegistry()

    /// The app's hotkeys.
    let hotkeys = HotkeyAction.settingsActions.map { action in
        Hotkey(action: action)
    }

    /// Encoder for properties.
    @ObservationIgnored
    private let encoder = JSONEncoder()

    /// Decoder for properties.
    @ObservationIgnored
    private let decoder = JSONDecoder()

    /// The shared app state.
    @ObservationIgnored
    private(set) weak var appState: AppState?

    /// Loads persisted bindings and begins observing subsequent edits.
    init() {
        loadInitialState()
        configureObservers()
    }

    /// Performs the initial setup of the model.
    func performSetup(with appState: AppState) {
        self.appState = appState
        for hotkey in hotkeys {
            hotkey.performSetup(with: appState)
        }
    }

    /// Loads the model's initial state.
    private func loadInitialState() {
        guard
            let dictionary = Defaults.dictionary(forKey: .hotkeys) as? [String: Data],
            !dictionary.isEmpty
        else {
            return
        }
        for hotkey in hotkeys {
            guard let data = dictionary[hotkey.action.rawValue] else {
                continue
            }
            do {
                if let keyCombination = try decoder.decode(KeyCombination?.self, from: data) {
                    hotkey.keyCombination = keyCombination
                }
            } catch {
                diagLog.error("Error decoding hotkey: \(error)")
            }
        }
    }

    /// Configures the internal observers for the model.
    ///
    /// Each hotkey's callback is assigned after ``loadInitialState()`` has
    /// already set its initial key combination, so — like the previous
    /// `dropFirst()` Combine pipeline — the initial value is never persisted
    /// redundantly, only subsequent changes.
    private func configureObservers() {
        for hotkey in hotkeys {
            hotkey.keyCombinationDidChange = { [weak self, weak hotkey] in
                guard let self, let hotkey else { return }
                do {
                    // Encoding the optional directly turns a cleared binding
                    // into the JSON literal `null` and stores it, leaving a
                    // dead entry behind for a hotkey the user just unbound.
                    // Remove the key instead, so the dictionary only ever
                    // holds bindings that actually exist.
                    let data = try hotkey.keyCombination.map { try encoder.encode($0) }
                    withMutableCopy(of: Defaults.dictionary(forKey: .hotkeys) ?? [:]) { dictionary in
                        if let data {
                            dictionary[hotkey.action.rawValue] = data
                        } else {
                            dictionary.removeValue(forKey: hotkey.action.rawValue)
                        }
                        Defaults.set(dictionary, forKey: .hotkeys)
                    }
                } catch {
                    self.diagLog.error("Error encoding hotkey: \(error)")
                }
            }
        }
    }

    /// Returns the hotkey with the given action.
    func hotkey(withAction action: HotkeyAction) -> Hotkey? {
        hotkeys.first { $0.action == action }
    }
}
