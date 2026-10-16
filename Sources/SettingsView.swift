//
//  SettingsView.swift
//  Everything that is not the chat: which Mac this app talks to, the token, and
//  the switch that belongs to the app rather than to a conversation.
//
//  It is a WINDOW of its own (a pushed screen of the menu's navigation stack),
//  not a panel inside the transcript, which is what it used to be: the connect
//  form sat as a card in the chat, in the path of the answer, and the moment a
//  stale address stopped answering it was the one screen the app could not reach
//  - Alex: "connect ui on iphone is broken. Lets focus on its redisining".
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var api: BishopAPI

    @State private var host = ""          // the fields, until Save/Connect reads them
    @State private var token = ""
    @State private var busy = false       // a connect attempt is in flight
    @State private var plain = false      // show the token's letters instead of dots

    var body: some View {
        Form {
            Section("Mac") {
                HStack(spacing: 8) {
                    Circle().fill(api.connected ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    Text(api.connected ? "Connected" : "Not connected")
                    Spacer()
                    Text(api.host).foregroundStyle(.secondary).lineLimit(1)
                }
                if !api.lastError.isEmpty {
                    Text(api.lastError).font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                TextField("192.168.2.12:8420", text: $host)
                    .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                HStack {
                    if plain {
                        TextField("token", text: $token)
                    } else {
                        SecureField("token", text: $token)
                    }
                    Button { plain.toggle() } label: {
                        Image(systemName: plain ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            } header: {
                Text("Address")
            } footer: {
                Text("The token is in ~/.bishop_web_token on the Mac. Saving keeps it on this phone; the Mac's address is what the app tries first, then its defaults.")
            }

            Section {
                Button {
                    save(); Task { await connect() }
                } label: {
                    HStack {
                        Text("Connect now")
                        if busy { Spacer(); ProgressView().controlSize(.small) }
                    }
                }
                .disabled(busy)
            } footer: {
                // No separate Save button: the only thing an address is FOR is
                // connecting, and a Save that saved a wrong address without saying
                // so would leave the reader no better off. Connect saves first.
                Text("Saving is part of connecting: the address and token are kept on this phone, so the next launch tries them first.")
            }

            Section("Try these addresses") {
                ForEach(api.candidates, id: \.self) { c in
                    Button {
                        host = c
                    } label: {
                        HStack {
                            // The candidate list is a menu of ADDRESSES, so a tap
                            // fills the field rather than connecting on the spot -
                            // connecting is the button above, and it is the one
                            // that reports what went wrong.
                            Text(c).font(.system(size: 14, design: .monospaced))
                            Spacer()
                            if c == api.host && api.connected { Image(systemName: "checkmark").foregroundStyle(.green) }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }

            Section("App") {
                Button("Restart the server") {
                    // webui.py reloads itself and every open client reconnects;
                    // the stream reopens on its own two seconds later.
                    Task { await api.restartServer() }
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear { host = api.host.isEmpty ? BishopAPI.DEFAULT_HOST : api.host; token = api.token }
    }

    /// The two fields become what the app will use: taken in, and written down.
    private func save() {
        api.host = host.trimmingCharacters(in: .whitespaces)
        api.token = token.trimmingCharacters(in: .whitespaces)
        api.save()
    }

    /// One connect attempt, with the button showing it is working: connect()
    /// walks the candidate list, so on a wrong address this is several timeouts
    /// long and a button that looks dead would invite a second tap.
    private func connect() async {
        save()
        busy = true
        await api.connect()
        busy = false
    }
}