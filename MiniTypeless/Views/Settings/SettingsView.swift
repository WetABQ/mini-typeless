import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            STTSettingsView()
                .tabItem { Label("Speech", systemImage: "waveform") }
            LLMSettingsView()
                .tabItem { Label("LLM", systemImage: "brain") }
            HistorySettingsView()
                .tabItem { Label("History", systemImage: "clock") }
            ModelManagerView()
                .tabItem { Label("Models", systemImage: "arrow.down.circle") }
        }
        .frame(width: 580, height: 550)
    }
}
