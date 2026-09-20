#if DELTA_SWITCH2KIT
import SwiftUI
import UIKit

struct Switch2ControllersView: View
{
    @ObservedObject private var service = Switch2ControllerService.shared

    var body: some View {
        Form {
            Section {
                Button("Find Switch 2 Controllers") { service.findControllers() }
                    .disabled(service.isStopping)
                Button("Disconnect All", role: .destructive) { service.stop() }
                    .disabled(!service.isStarted || service.isStopping)
                Text(service.status)
                    .foregroundStyle(.secondary)
                if service.needsBluetoothPermission
                {
                    Button("Open Bluetooth Permissions") {
                        if let url = URL(string: UIApplication.openSettingsURLString)
                        {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            } footer: {
                Text("Choose Find, allow Bluetooth access, then hold the controller’s Sync button. Close Dolphin, Cemu, and other apps managing the controller first. Discovery lasts 60 seconds.")
            }
            if let error = service.errorMessage
            {
                Section("Controller Error") { Text(error) }
            }
            Section("Connected Controllers") {
                if service.controllers.isEmpty
                {
                    Text("No Switch 2 controllers connected.")
                        .foregroundStyle(.secondary)
                }
                ForEach(service.controllers, id: \.connectionID) { controller in
                    Text(controller.name)
                }
            }
            Section {
                Text("Return to Controllers and choose a Player to assign or customize controls. Home opens Delta’s menu; the left Joy-Con uses Capture. Hold individual Joy-Con halves horizontally with the stick on the left.")
                Text("Experimental iOS support. Controller pairing and gameplay still need physical-device qualification. No combined Joy-Con pair, motion, mouse, or game rumble support is provided by this adapter. Backgrounding disconnects controllers; choose Find again after returning.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Switch 2 Controllers")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
