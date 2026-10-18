//
//  BishopApp.swift
//  Bishop on the phone: the same chat as the web page, talking to webui.py on
//  the Mac. The voice mic uses the native keyboard's dictation, so there is no
//  speech framework here on purpose.
//

import SwiftUI

@main
struct BishopApp: App {
    var body: some Scene {
        WindowGroup { ChatView() }
    }
}
