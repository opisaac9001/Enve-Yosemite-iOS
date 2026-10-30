import SwiftUI
import CoreLocation

/// Pure rules for the parked-car pin: note normalisation and what the Valley map can show.
enum ParkedCar {
    static func pin(at coordinate: CLLocationCoordinate2D, basis: CarPinBasis, note: String) -> SavedCar {
        SavedCar(latitude: coordinate.latitude, longitude: coordinate.longitude, note: normalised(note), basis: basis, updatedAt: .stamp)
    }

    static func normalised(_ note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The bundled Valley map only covers its own extent; a pin beyond it is real but cannot be shown there.
    static func isOnValleyMap(_ coordinate: CLLocationCoordinate2D) -> Bool {
        YosemiteGeo.valleyBounds.contains(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func externalMapURL(for car: SavedCar) -> URL? {
        WaterIceGuide.externalMapURL(latitude: car.latitude, longitude: car.longitude, label: "Parked car")
    }

    static func describe(_ car: SavedCar) -> String {
        "\(car.basis == .location ? "From your position" : "Placed by hand") · \(DateText.short(car.updatedAt))"
    }
}

/// Explicit parked-car panel: note, existing pin, location request, crosshair placement, clear.
/// Nothing is written until the visitor saves; cancelling leaves the previous pin untouched.
struct ParkedCarSheet: View {
    let existing: SavedCar?
    let proposed: CLLocationCoordinate2D?
    @Binding var note: String
    let onUseLocation: () -> Void
    let onChooseOnMap: () -> Void
    let onSave: (CLLocationCoordinate2D, CarPinBasis) -> Void
    let onShowOnMap: () -> Void
    let onClear: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                if let proposed {
                    Section("Chosen spot") {
                        Text(String(format: "%.5f, %.5f", proposed.latitude, proposed.longitude)).font(.fieldMono)
                        if !ParkedCar.isOnValleyMap(proposed) {
                            Text("Outside the bundled Valley map; the pin will be saved but cannot be drawn there.").font(.fieldCaption).foregroundStyle(Palette.ember)
                        }
                        Button { onSave(proposed, .manual); dismiss() } label: { Label(existing == nil ? "Set parked car here" : "Move parked car here", systemImage: "car.fill") }
                            .accessibilityHint("Saves this spot with your note")
                    }
                } else if let existing {
                    Section("Current pin") {
                        Text(ParkedCar.describe(existing)).font(.fieldCaption)
                        Text(String(format: "%.5f, %.5f", existing.latitude, existing.longitude)).font(.fieldMono).foregroundStyle(.secondary)
                        if ParkedCar.isOnValleyMap(existing.coordinate) {
                            Button { dismiss(); onShowOnMap() } label: { Label("Show on the Valley map", systemImage: "map") }
                        } else {
                            Text("This pin lies outside the bundled Valley map, so it cannot be drawn there.").font(.fieldCaption).foregroundStyle(Palette.ember)
                            if let url = ParkedCar.externalMapURL(for: existing) { ExternalLinkRow(label: "Open the coordinates in Apple Maps", url: url) }
                        }
                        Button { onSave(existing.coordinate, existing.basis); dismiss() } label: { Label("Save note", systemImage: "square.and.pencil") }
                            .disabled(ParkedCar.normalised(note) == existing.note)
                        Button(role: .destructive) { confirmClear = true } label: { Label("Clear pin", systemImage: "trash") }
                    }
                } else {
                    Section("Current pin") { Text("No parked car pinned yet.").font(.fieldCaption).foregroundStyle(.secondary) }
                }
                Section("Note") {
                    TextField("Optional, e.g. row C near the restroom", text: $note, axis: .vertical).lineLimit(1...4)
                }
                Section(proposed == nil ? "Set the spot" : "Or set it another way") {
                    Button { dismiss(); onUseLocation() } label: { Label("Use my location", systemImage: "location") }
                        .accessibilityHint("Asks for location permission the first time, then pins your current position")
                    Button { dismiss(); onChooseOnMap() } label: { Label("Choose on map", systemImage: "scope") }
                        .accessibilityHint("Shows a crosshair; move the map, then confirm the spot")
                }
                Section {
                    Text("The pin and note stay on this device and travel only in your explicit backups, never in shared links. Accuracy depends on the point you choose or on the location reading.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Parked car")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .confirmationDialog("Clear the parked-car pin?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear pin", role: .destructive) { onClear(); dismiss() }
            } message: { Text("Removes the pin and its note from this device.") }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Crosshair mode shown over the Valley map; the pin is only written on explicit confirmation.
struct ParkedCarPlacementBar: View {
    let note: String
    let onSet: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Move the map until the crosshair sits on your car.", systemImage: "scope").font(.fieldCaption)
            if let note = ParkedCar.normalised(note) { Text("Note: \(note)").font(.caption2).foregroundStyle(.secondary) }
            HStack {
                Button(action: onSet) { Label("Set parked car here", systemImage: "car.fill") }.buttonStyle(.borderedProminent)
                Button("Cancel", role: .cancel, action: onCancel).buttonStyle(.bordered)
            }
            .font(.fieldCaption)
        }
        .padding(12)
        .background(Palette.card(scheme), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
