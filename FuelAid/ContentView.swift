//
//  ContentView.swift
//  FuelAid
//
//  Created by ERIC DIEVENDORF on 5/17/26.
//

import CoreData
import CoreLocation
import MapKit
import StoreKit
import SwiftUI

enum TripType: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case business = "Business"
    case towing = "Towing"

    var id: String { rawValue }
}

enum FuelVolumeUnit: String, CaseIterable, Identifiable {
    case gallons = "Gallons"
    case liters = "Liters"

    var id: String { rawValue }
    var abbreviation: String { self == .gallons ? "gal" : "L" }
    var singularName: String { self == .gallons ? "Gallon" : "Liter" }
}

enum DistanceUnit: String, CaseIterable, Identifiable {
    case miles = "Miles"
    case kilometers = "Kilometers"

    var id: String { rawValue }
    var abbreviation: String { self == .miles ? "mi" : "km" }
    var speedAbbreviation: String { self == .miles ? "mph" : "km/h" }
}

enum LocationLookupError: LocalizedError {
    case denied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Location permission is required to auto log fill up locations."
        case .unavailable:
            return "Unable to identify the current location."
        }
    }
}

@MainActor
final class LocationLookupService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func currentPlaceName() async throws -> String {
        let location = try await currentLocation()
        guard let request = MKReverseGeocodingRequest(location: location) else {
            throw LocationLookupError.unavailable
        }

        let mapItems = try await mapItems(for: request)
        guard let mapItem = mapItems.first else {
            throw LocationLookupError.unavailable
        }

        return mapItem.name
            ?? "Current Location"
    }

    private func mapItems(for request: MKReverseGeocodingRequest) async throws -> [MKMapItem] {
        try await withCheckedThrowingContinuation { continuation in
            request.getMapItems { mapItems, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(returning: mapItems ?? [])
            }
        }
    }

    private func currentLocation() async throws -> CLLocation {
        let status = manager.authorizationStatus

        guard status != .denied, status != .restricted else {
            throw LocationLookupError.denied
        }

        if status == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let location = locations.last else {
                continuation?.resume(throwing: LocationLookupError.unavailable)
                continuation = nil
                return
            }

            continuation?.resume(returning: location)
            continuation = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

struct MeasurementPreferences {
    static let litersPerGallon = 3.785411784
    static let kilometersPerMile = 1.609344

    var fuelVolumeUnit = FuelVolumeUnit.gallons
    var distanceUnit = DistanceUnit.miles

    func gallons(fromDisplayedVolume value: Double) -> Double {
        fuelVolumeUnit == .gallons ? value : value / Self.litersPerGallon
    }

    func displayedVolume(fromGallons gallons: Double) -> Double {
        fuelVolumeUnit == .gallons ? gallons : gallons * Self.litersPerGallon
    }

    func pricePerGallon(fromDisplayedPrice value: Double) -> Double {
        fuelVolumeUnit == .gallons ? value : value * Self.litersPerGallon
    }

    func miles(fromDisplayedDistance value: Double) -> Double {
        distanceUnit == .miles ? value : value / Self.kilometersPerMile
    }

    func displayedDistance(fromMiles miles: Double) -> Double {
        distanceUnit == .miles ? miles : miles * Self.kilometersPerMile
    }

    func displayedEfficiency(miles: Double, gallons: Double) -> Double? {
        guard miles > 0, gallons > 0 else { return nil }
        return displayedDistance(fromMiles: miles) / displayedVolume(fromGallons: gallons)
    }

    var efficiencyAbbreviation: String {
        "\(distanceUnit.abbreviation)/\(fuelVolumeUnit.abbreviation)"
    }

    var efficiencyDescription: String {
        "\(distanceUnit.rawValue) per \(fuelVolumeUnit.singularName)"
    }

    func formattedVolume(gallons: Double) -> String {
        "\(displayedVolume(fromGallons: gallons).formatted(.number.precision(.fractionLength(1)))) \(fuelVolumeUnit.abbreviation)"
    }

    func formattedDistance(miles: Double) -> String {
        "\(displayedDistance(fromMiles: miles).formatted(.number.precision(.fractionLength(1)))) \(distanceUnit.abbreviation)"
    }
}

struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(SubscriptionStore.self) private var subscriptionStore

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Vehicle.name, ascending: true)], animation: .default)
    private var vehicles: FetchedResults<Vehicle>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \FillUp.date, ascending: false)], animation: .default)
    private var fillUps: FetchedResults<FillUp>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Trip.startDate, ascending: false)], animation: .default)
    private var trips: FetchedResults<Trip>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \AppPreference.createdAt, ascending: true)], animation: .default)
    private var preferences: FetchedResults<AppPreference>

    @State private var showingVehicleForm = false
    @State private var showingFillUpForm = false
    @State private var showingTripForm = false
    @State private var showingUpgrade = false
    @State private var selectedVehicleID: NSManagedObjectID?
    @State private var measurementRefreshID = UUID()

    private var defaultVehicle: Vehicle? {
        activeVehicles.first(where: { $0.isDefault }) ?? activeVehicles.first
    }

    private var selectedVehicle: Vehicle? {
        guard let selectedVehicleID,
              let vehicle = activeVehicles.first(where: { $0.objectID == selectedVehicleID }) else {
            return defaultVehicle
        }

        return vehicle
    }

    private var activeVehicles: [Vehicle] {
        vehicles.filter { !$0.isArchivedForDisplay }
    }

    private var measurementPreferences: MeasurementPreferences {
        preferences.first?.measurementPreferences ?? MeasurementPreferences()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    QuickFuelCard(vehicles: activeVehicles, selectedVehicleID: $selectedVehicleID, selectedVehicle: selectedVehicle, addAction: { showingFillUpForm = true })
                    MPGTrendCard(vehicle: selectedVehicle, fillUps: Array(fillUps), measurements: measurementPreferences)
                        .id(measurementRefreshID)
                    PlanStatusCard(vehicleCount: vehicles.count)
                    DashboardLinks(showUpgrade: { showingUpgrade = true })
                    RecentActivityCard(fillUps: Array(fillUps.prefix(3)), trips: Array(trips.prefix(3)), measurements: measurementPreferences)
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("FuelAid")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Log Fill-Up", systemImage: "fuelpump") { showingFillUpForm = true }
                        Button("Start Trip", systemImage: "map") { showingTripForm = true }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .sheet(isPresented: $showingVehicleForm) {
                VehicleForm { saveVehicle($0) }
            }
            .sheet(isPresented: $showingFillUpForm) {
                FillUpForm(vehicles: activeVehicles, defaultVehicle: selectedVehicle, autoLogLocation: preferences.first?.autoLogFillUpLocations ?? true, measurements: measurementPreferences) {
                    saveFillUp($0)
                }
            }
            .sheet(isPresented: $showingTripForm) {
                TripForm(vehicles: activeVehicles, defaultVehicle: defaultVehicle, measurements: measurementPreferences) {
                    saveTrip($0)
                }
            }
            .sheet(isPresented: $showingUpgrade) {
                UpgradeView()
            }
            .onAppear(perform: ensurePreferencesExist)
            .onAppear(perform: selectDefaultVehicleIfNeeded)
            .onChange(of: defaultVehicle?.objectID) { _, _ in
                selectDefaultVehicleIfNeeded()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSManagedObjectContextObjectsDidChange, object: viewContext)) { notification in
                refreshMeasurementsIfNeeded(for: notification)
            }
        }
    }

    private func selectDefaultVehicleIfNeeded() {
        if let selectedVehicleID,
           activeVehicles.contains(where: { $0.objectID == selectedVehicleID }) {
            return
        }

        selectedVehicleID = defaultVehicle?.objectID
    }

    private func refreshMeasurementsIfNeeded(for notification: Notification) {
        let changedObjects = [
            NSUpdatedObjectsKey,
            NSInsertedObjectsKey,
            NSRefreshedObjectsKey
        ]
            .compactMap { notification.userInfo?[$0] as? Set<NSManagedObject> }
            .flatMap { $0 }

        if changedObjects.contains(where: { $0 is AppPreference }) {
            measurementRefreshID = UUID()
        }
    }

    private func showVehicleEntry() {
        if subscriptionStore.canAddVehicle(currentCount: activeVehicles.count) {
            showingVehicleForm = true
        } else {
            showingUpgrade = true
        }
    }

    private func saveVehicle(_ draft: VehicleDraft) {
        guard subscriptionStore.canAddVehicle(currentCount: activeVehicles.count) else {
            showingUpgrade = true
            return
        }

        let vehicle = Vehicle(context: viewContext)
        assignToPrivateStore(vehicle)
        vehicle.id = UUID()
        vehicle.createdAt = Date()
        apply(draft, to: vehicle)
        vehicle.setValue(false, forKey: "isArchived")
        vehicle.setValue(nil, forKey: "archivedAt")
        vehicle.isDefault = activeVehicles.isEmpty || draft.isDefault

        if vehicle.isDefault {
            vehicles.forEach { $0.isDefault = false }
        }

        saveContext()
    }

    private func saveFillUp(_ draft: FillUpDraft) {
        let fillUp = FillUp(context: viewContext)
        assignToPrivateStore(fillUp)
        fillUp.id = UUID()
        fillUp.date = draft.date
        fillUp.vehicle = draft.vehicle
        fillUp.odometer = measurementPreferences.miles(fromDisplayedDistance: Double(draft.odometer) ?? 0)
        fillUp.gallons = measurementPreferences.gallons(fromDisplayedVolume: Double(draft.gallons) ?? 0)
        fillUp.pricePerGallon = measurementPreferences.pricePerGallon(fromDisplayedPrice: Double(draft.pricePerGallon) ?? 0)
        fillUp.totalCost = fillUp.gallons * fillUp.pricePerGallon
        fillUp.location = draft.location
        fillUp.autoLoggedLocation = draft.autoLoggedLocation
        saveContext()
    }

    private func saveTrip(_ draft: TripDraft) {
        let trip = Trip(context: viewContext)
        assignToPrivateStore(trip)
        trip.id = UUID()
        trip.name = draft.name
        trip.vehicle = draft.vehicle
        trip.startDate = draft.startDate
        trip.endDate = draft.endDate
        trip.startLocation = draft.startLocation
        trip.endLocation = draft.endLocation
        trip.route = draft.route
        trip.distance = measurementPreferences.miles(fromDisplayedDistance: Double(draft.distance) ?? 0)
        trip.averageSpeed = measurementPreferences.miles(fromDisplayedDistance: Double(draft.averageSpeed) ?? 0)
        trip.tripType = draft.tripType.rawValue
        saveContext()
    }

    private func ensurePreferencesExist() {
        guard preferences.isEmpty else { return }

        let preference = AppPreference(context: viewContext)
        assignToPrivateStore(preference)
        preference.id = UUID()
        preference.createdAt = Date()
        preference.autoLogFillUpLocations = true
        preference.setValue(FuelVolumeUnit.gallons.rawValue, forKey: "fuelVolumeUnit")
        preference.setValue(DistanceUnit.miles.rawValue, forKey: "distanceUnit")
        saveContext()
    }

    private func assignToPrivateStore(_ object: NSManagedObject) {
        guard let store = viewContext.persistentStoreCoordinator?.persistentStores.first(where: { $0.url?.lastPathComponent != "Shared.sqlite" }) else {
            return
        }

        viewContext.assign(object, to: store)
    }

    private func saveContext() {
        do {
            try viewContext.save()
        } catch {
            let nsError = error as NSError
            assertionFailure("Unresolved Core Data error \(nsError), \(nsError.userInfo)")
        }
    }
}

private struct PlanStatusCard: View {
    @Environment(SubscriptionStore.self) private var subscriptionStore

    let vehicleCount: Int

    private var vehicleLimitText: String {
        if let limit = subscriptionStore.vehicleLimit {
            return "\(vehicleCount)/\(limit) vehicles"
        }

        return "\(vehicleCount) vehicles"
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: subscriptionStore.hasProAccess ? "checkmark.seal.fill" : "lock.open")
                .font(.title2)
                .foregroundStyle(subscriptionStore.hasProAccess ? .green : .blue)

            VStack(alignment: .leading, spacing: 4) {
                Text(subscriptionStore.planName)
                    .font(.headline)
                Text(subscriptionStore.hasProAccess ? "All premium features unlocked" : "\(vehicleLimitText) included")
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DashboardLinks: View {
    let showUpgrade: () -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            NavigationLink(value: "vehicles") {
                DashboardLink(title: "Vehicles", systemImage: "car.2")
            }
            NavigationLink(value: "trips") {
                DashboardLink(title: "Trips", systemImage: "map")
            }
            NavigationLink(value: "reports") {
                DashboardLink(title: "Reports", systemImage: "chart.line.uptrend.xyaxis")
            }
            NavigationLink(value: "settings") {
                DashboardLink(title: "Settings", systemImage: "gearshape")
            }

            Button(action: showUpgrade) {
                LockedDashboardLink(title: "Advanced Reports", systemImage: "chart.bar.xaxis")
            }
            Button(action: showUpgrade) {
                LockedDashboardLink(title: "Import / Export", systemImage: "square.and.arrow.up.on.square")
            }
            Button(action: showUpgrade) {
                LockedDashboardLink(title: "Maintenance", systemImage: "wrench.and.screwdriver")
            }
            Button(action: showUpgrade) {
                LockedDashboardLink(title: "Trailers", systemImage: "box.truck")
            }
        }
        .buttonStyle(.plain)
        .navigationDestination(for: String.self) { destination in
            switch destination {
            case "vehicles":
                VehicleListView()
            case "trips":
                TripListView()
            case "reports":
                ReportsView()
            default:
                SettingsView()
            }
        }
    }
}

private struct LockedDashboardLink: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
        }
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: 64)
        .padding(.horizontal, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct DashboardLink: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct QuickFuelCard: View {
    let vehicles: [Vehicle]
    @Binding var selectedVehicleID: NSManagedObjectID?
    let selectedVehicle: Vehicle?
    let addAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if vehicles.isEmpty {
                        Text("No Vehicle Selected")
                            .font(.title3.weight(.semibold))
                    } else {
                        Menu {
                            ForEach(vehicles, id: \.objectID) { vehicle in
                                Button {
                                    selectedVehicleID = vehicle.objectID
                                } label: {
                                    if selectedVehicleID == vehicle.objectID {
                                        Label(vehicle.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(vehicle.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(selectedVehicle?.displayName ?? "Select Vehicle")
                                    .font(.title3.weight(.semibold))
                                Image(systemName: "chevron.down.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Quick fuel entry")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: addAction) {
                    Label("Log", systemImage: "fuelpump.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedVehicle == nil)
            }

        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MPGTrendCard: View {
    let vehicle: Vehicle?
    let fillUps: [FillUp]
    let measurements: MeasurementPreferences

    private var points: [Double] {
        guard let vehicle else { return [] }

        let vehicleFillUps = fillUps
            .filter { $0.vehicle == vehicle }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }

        guard vehicleFillUps.count > 1 else { return [] }

        return vehicleFillUps.indices.dropFirst().compactMap { index in
            let current = vehicleFillUps[index]
            let previous = vehicleFillUps[index - 1]
            let miles = current.odometer - previous.odometer
            return measurements.displayedEfficiency(miles: miles, gallons: current.gallons)
        }
    }

    private var title: String {
        if measurements.distanceUnit == .miles && measurements.fuelVolumeUnit == .gallons {
            return "MPG Trend"
        }

        return "Fuel Economy Trend (\(measurements.efficiencyDescription))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text(points.last.map { "\($0, specifier: "%.1f") \(measurements.efficiencyAbbreviation)" } ?? "No data")
                    .foregroundStyle(.secondary)
            }

            if points.count > 1 {
                MPGLineGraph(points: points, unit: measurements.efficiencyAbbreviation)
                    .frame(height: 140)
            } else {
                ContentUnavailableView(
                    "Not Enough Fuel History",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Log at least two fill ups for this vehicle.")
                )
                .frame(height: 140)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MPGLineGraph: View {
    let points: [Double]
    let unit: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(.tertiarySystemGroupedBackground))

                Path { path in
                    let horizontalStep = proxy.size.height / 3

                    for index in 1...2 {
                        let y = horizontalStep * CGFloat(index)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                    }
                }
                .stroke(Color(.separator).opacity(0.35), lineWidth: 1)

                Path { path in
                    guard let minValue = points.min(), let maxValue = points.max() else { return }

                    let horizontalInset: CGFloat = 10
                    let verticalInset: CGFloat = 24
                    let width = max(proxy.size.width - horizontalInset * 2, 1)
                    let height = max(proxy.size.height - verticalInset * 2, 1)
                    let range = max(maxValue - minValue, 1)

                    for index in points.indices {
                        let x = horizontalInset + width * CGFloat(index) / CGFloat(points.count - 1)
                        let y = verticalInset + height - ((points[index] - minValue) / range * height)
                        let point = CGPoint(x: x, y: y)

                        if index == points.startIndex {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

                ForEach(Array(points.enumerated()), id: \.offset) { index, value in
                    if let minValue = points.min(), let maxValue = points.max() {
                        let horizontalInset: CGFloat = 10
                        let verticalInset: CGFloat = 24
                        let width = max(proxy.size.width - horizontalInset * 2, 1)
                        let height = max(proxy.size.height - verticalInset * 2, 1)
                        let range = max(maxValue - minValue, 1)
                        let x = horizontalInset + width * CGFloat(index) / CGFloat(points.count - 1)
                        let y = verticalInset + height - ((value - minValue) / range * height)

                        Circle()
                            .fill(.green)
                            .frame(width: 7, height: 7)
                            .position(x: x, y: y)

                        Text(value.formatted(.number.precision(.fractionLength(1))))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(.thinMaterial, in: Capsule())
                            .position(x: x, y: max(y - 15, 10))
                    }
                }
            }
        }
    }
}

private struct RecentActivityCard: View {
    let fillUps: [FillUp]
    let trips: [Trip]
    let measurements: MeasurementPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            if fillUps.isEmpty && trips.isEmpty {
                Text("No fuel or trip records yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fillUps, id: \.objectID) { fillUp in
                    Label("\(fillUp.vehicle?.displayName ?? "Vehicle") fuel: \(measurements.formattedVolume(gallons: fillUp.gallons))", systemImage: "fuelpump")
                }

                ForEach(trips, id: \.objectID) { trip in
                    Label("\(trip.name?.nilIfEmpty ?? "Trip"): \(measurements.formattedDistance(miles: trip.distance))", systemImage: "map")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct VehicleListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(SubscriptionStore.self) private var subscriptionStore
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Vehicle.name, ascending: true)], animation: .default)
    private var vehicles: FetchedResults<Vehicle>

    @State private var showingVehicleForm = false
    @State private var showingUpgrade = false

    private var activeVehicles: [Vehicle] {
        vehicles.filter { !$0.isArchivedForDisplay }
    }

    private var archivedVehicles: [Vehicle] {
        vehicles
            .filter(\.isArchivedForDisplay)
            .sorted { ($0.archivedAtForDisplay ?? .distantPast) > ($1.archivedAtForDisplay ?? .distantPast) }
    }

    var body: some View {
        List {
            Section("Vehicles") {
                if activeVehicles.isEmpty {
                    Text("No active vehicles.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activeVehicles, id: \.objectID) { vehicle in
                        NavigationLink {
                            VehicleEditorView(vehicle: vehicle, allVehicles: Array(vehicles))
                        } label: {
                            VehicleRow(vehicle: vehicle)
                        }
                        .swipeActions {
                            Button {
                                vehicles.forEach { $0.isDefault = false }
                                vehicle.isDefault = true
                                try? viewContext.save()
                            } label: {
                                Label("Default", systemImage: "star")
                            }
                            .tint(.yellow)
                        }
                    }
                }
            }

            if let limit = subscriptionStore.vehicleLimit {
                Section {
                    Label("Free version supports up to \(limit) vehicles", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }

            if !archivedVehicles.isEmpty {
                Section("Archived") {
                    ForEach(archivedVehicles, id: \.objectID) { vehicle in
                        NavigationLink {
                            VehicleEditorView(vehicle: vehicle, allVehicles: Array(vehicles))
                        } label: {
                            VehicleRow(vehicle: vehicle)
                        }
                    }
                }
            }
        }
        .navigationTitle("Vehicles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showVehicleEntry) {
                    Image(systemName: "plus.circle.fill")
                }
            }
        }
        .sheet(isPresented: $showingVehicleForm) {
            VehicleForm { saveVehicle($0) }
        }
        .sheet(isPresented: $showingUpgrade) {
            UpgradeView()
        }
    }

    private func showVehicleEntry() {
        if subscriptionStore.canAddVehicle(currentCount: activeVehicles.count) {
            showingVehicleForm = true
        } else {
            showingUpgrade = true
        }
    }

    private func saveVehicle(_ draft: VehicleDraft) {
        guard subscriptionStore.canAddVehicle(currentCount: activeVehicles.count) else {
            showingUpgrade = true
            return
        }

        let vehicle = Vehicle(context: viewContext)
        vehicle.id = UUID()
        vehicle.createdAt = Date()
        apply(draft, to: vehicle)
        vehicle.setValue(false, forKey: "isArchived")
        vehicle.setValue(nil, forKey: "archivedAt")
        vehicle.isDefault = activeVehicles.isEmpty || draft.isDefault

        if vehicle.isDefault {
            vehicles.forEach { $0.isDefault = false }
        }

        try? viewContext.save()
    }
}

private struct VehicleRow: View {
    let vehicle: Vehicle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(vehicle.displayName)
                    .font(.headline)
                if vehicle.isDefault {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                }
            }
            Text("\(vehicle.year == 0 ? "" : String(vehicle.year)) \(vehicle.make ?? "") \(vehicle.model ?? "")")
                .foregroundStyle(.secondary)
            Text("Plate: \(vehicle.licensePlate?.nilIfEmpty ?? "Not set")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct VehicleEditorView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var vehicle: Vehicle

    let allVehicles: [Vehicle]

    @State private var draft: VehicleDraft
    @State private var showingDeleteConfirmation = false

    init(vehicle: Vehicle, allVehicles: [Vehicle]) {
        self.vehicle = vehicle
        self.allVehicles = allVehicles
        _draft = State(initialValue: VehicleDraft(vehicle: vehicle))
    }

    var body: some View {
        Form {
            VehicleFields(draft: $draft)

            Section {
                if vehicle.isArchivedForDisplay {
                    Button("Unarchive Vehicle", systemImage: "arrow.up.bin") {
                        unarchiveVehicle()
                    }
                } else {
                    Button("Archive Vehicle", systemImage: "archivebox") {
                        archiveVehicle()
                    }
                }

                Button("Delete Vehicle", systemImage: "trash", role: .destructive) {
                    showingDeleteConfirmation = true
                }
            }
        }
        .navigationTitle("Edit Vehicle")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveVehicle()
                }
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .alert("Delete Vehicle?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                deleteVehicle()
            }
        } message: {
            Text("This will permanently delete this vehicle and its related fuel and trip records.")
        }
    }

    private func saveVehicle() {
        apply(draft, to: vehicle)

        if !vehicle.isArchivedForDisplay {
            if draft.isDefault {
                allVehicles.forEach { $0.isDefault = false }
                vehicle.isDefault = true
            } else if vehicle.isDefault {
                vehicle.isDefault = false
                promoteDefaultVehicle(excluding: vehicle)
            }
        }

        try? viewContext.save()
        dismiss()
    }

    private func archiveVehicle() {
        vehicle.setValue(true, forKey: "isArchived")
        vehicle.setValue(Date(), forKey: "archivedAt")

        if vehicle.isDefault {
            vehicle.isDefault = false
            promoteDefaultVehicle(excluding: vehicle)
        }

        try? viewContext.save()
        dismiss()
    }

    private func unarchiveVehicle() {
        vehicle.setValue(false, forKey: "isArchived")
        vehicle.setValue(nil, forKey: "archivedAt")

        if !allVehicles.contains(where: { $0 != vehicle && !$0.isArchivedForDisplay && $0.isDefault }) {
            vehicle.isDefault = true
        }

        try? viewContext.save()
        dismiss()
    }

    private func deleteVehicle() {
        let shouldPromoteDefault = vehicle.isDefault
        viewContext.delete(vehicle)

        if shouldPromoteDefault {
            promoteDefaultVehicle(excluding: vehicle)
        }

        try? viewContext.save()
        dismiss()
    }

    private func promoteDefaultVehicle(excluding vehicleToExclude: Vehicle) {
        guard let nextDefault = allVehicles.first(where: { vehicle in
            vehicle != vehicleToExclude && !vehicle.isArchivedForDisplay
        }) else {
            return
        }

        nextDefault.isDefault = true
    }
}

private struct TripListView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Trip.startDate, ascending: false)], animation: .default)
    private var trips: FetchedResults<Trip>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \AppPreference.createdAt, ascending: true)], animation: .default)
    private var preferences: FetchedResults<AppPreference>

    private var measurements: MeasurementPreferences {
        preferences.first?.measurementPreferences ?? MeasurementPreferences()
    }

    var body: some View {
        List(trips, id: \.objectID) { trip in
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.name?.nilIfEmpty ?? "Trip")
                    .font(.headline)
                Text("\(trip.vehicle?.displayName ?? "Vehicle") - \(trip.tripType ?? TripType.standard.rawValue)")
                    .foregroundStyle(.secondary)
                Text("\(trip.startLocation?.nilIfEmpty ?? "Start") to \(trip.endLocation?.nilIfEmpty ?? "End") - \(measurements.formattedDistance(miles: trip.distance))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Trips")
    }
}

private struct ReportsView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Vehicle.name, ascending: true)], animation: .default)
    private var vehicles: FetchedResults<Vehicle>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \FillUp.date, ascending: true)], animation: .default)
    private var fillUps: FetchedResults<FillUp>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Trip.startDate, ascending: true)], animation: .default)
    private var trips: FetchedResults<Trip>

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \AppPreference.createdAt, ascending: true)], animation: .default)
    private var preferences: FetchedResults<AppPreference>

    private var measurements: MeasurementPreferences {
        preferences.first?.measurementPreferences ?? MeasurementPreferences()
    }

    var body: some View {
        List {
            Section("Fuel") {
                ForEach(vehicles, id: \.objectID) { vehicle in
                    LabeledContent(vehicle.displayName, value: formattedFuelCost(for: vehicle))
                }
            }

            Section("Trip Mileage") {
                ForEach(TripType.allCases) { tripType in
                    LabeledContent(tripType.rawValue, value: formattedMileage(for: tripType))
                }
            }
        }
        .navigationTitle("Reports")
    }

    private func formattedFuelCost(for vehicle: Vehicle) -> String {
        let totalCost = fillUps
            .filter { $0.vehicle == vehicle }
            .reduce(0) { $0 + $1.totalCost }

        return totalCost.formatted(.currency(code: Locale.current.currency?.identifier ?? "USD"))
    }

    private func formattedMileage(for tripType: TripType) -> String {
        let mileage = trips
            .filter { $0.tripType == tripType.rawValue }
            .reduce(0) { $0 + $1.distance }

        return measurements.formattedDistance(miles: mileage)
    }
}

private struct SettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(SubscriptionStore.self) private var subscriptionStore
    @State private var showingUpgrade = false

    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \AppPreference.createdAt, ascending: true)], animation: .default)
    private var preferences: FetchedResults<AppPreference>

    var body: some View {
        Form {
            Section("Fuel Logging") {
                Toggle("Auto Log Fill Up Location", isOn: Binding(
                    get: { preferences.first?.autoLogFillUpLocations ?? true },
                    set: { newValue in
                        preferences.first?.autoLogFillUpLocations = newValue
                        try? viewContext.save()
                    }
                ))
            }

            Section("Measurements") {
                Picker("Fuel volume", selection: fuelVolumeUnitBinding) {
                    ForEach(FuelVolumeUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }

                Picker("Distance", selection: distanceUnitBinding) {
                    ForEach(DistanceUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
            }

            Section("Plan") {
                LabeledContent("Current plan", value: subscriptionStore.planName)
                Button("Upgrade options") {
                    showingUpgrade = true
                }
            }

            Section("Paid Features") {
                ForEach(PremiumFeature.allCases) { feature in
                    HStack {
                        Label(feature.rawValue, systemImage: feature.systemImage)
                        Spacer()
                        Image(systemName: subscriptionStore.hasProAccess ? "checkmark.circle.fill" : "lock.fill")
                            .foregroundStyle(subscriptionStore.hasProAccess ? .green : .secondary)
                    }
                }
            }

            Section("iCloud") {
                LabeledContent("Container", value: PersistenceController.cloudKitContainerIdentifier)
                Text("Vehicle shares use Core Data and CloudKit shared databases.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingUpgrade) {
            UpgradeView()
        }
    }

    private var fuelVolumeUnitBinding: Binding<FuelVolumeUnit> {
        Binding(
            get: { FuelVolumeUnit(rawValue: preferences.first?.value(forKey: "fuelVolumeUnit") as? String ?? "") ?? .gallons },
            set: { newValue in
                preferences.first?.setValue(newValue.rawValue, forKey: "fuelVolumeUnit")
                try? viewContext.save()
            }
        )
    }

    private var distanceUnitBinding: Binding<DistanceUnit> {
        Binding(
            get: { DistanceUnit(rawValue: preferences.first?.value(forKey: "distanceUnit") as? String ?? "") ?? .miles },
            set: { newValue in
                preferences.first?.setValue(newValue.rawValue, forKey: "distanceUnit")
                try? viewContext.save()
            }
        )
    }
}

private struct VehicleForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = VehicleDraft()

    let onSave: (VehicleDraft) -> Void

    var body: some View {
        NavigationStack {
            Form {
                VehicleFields(draft: $draft)
            }
            .navigationTitle("Add Vehicle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct VehicleFields: View {
    @Binding var draft: VehicleDraft

    var body: some View {
        Section("Vehicle") {
            TextField("Vehicle name", text: $draft.name)
            TextField("Make", text: $draft.make)
            TextField("Model", text: $draft.model)
            TextField("Year", text: $draft.year)
                .keyboardType(.numberPad)
            TextField("VIN", text: $draft.vin)
                .textInputAutocapitalization(.characters)
            TextField("License plate", text: $draft.licensePlate)
                .textInputAutocapitalization(.characters)
            TextField("Recommended tire pressure", text: $draft.recommendedTirePressure)
                .keyboardType(.decimalPad)
            Toggle("Set as default vehicle", isOn: $draft.isDefault)
        }
    }
}

private struct FillUpForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FillUpDraft
    @State private var isLookingUpLocation = false
    @State private var locationError: String?

    private let locationLookupService = LocationLookupService()

    let vehicles: [Vehicle]
    let measurements: MeasurementPreferences
    let onSave: (FillUpDraft) -> Void

    init(vehicles: [Vehicle], defaultVehicle: Vehicle?, autoLogLocation: Bool, measurements: MeasurementPreferences, onSave: @escaping (FillUpDraft) -> Void) {
        self.vehicles = vehicles
        self.measurements = measurements
        self.onSave = onSave
        _draft = State(initialValue: FillUpDraft(vehicle: defaultVehicle, autoLoggedLocation: autoLogLocation))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Vehicle", selection: $draft.vehicle) {
                    ForEach(vehicles, id: \.objectID) { vehicle in
                        Text(vehicle.displayName).tag(Optional(vehicle))
                    }
                }
                DatePicker("Date and time", selection: $draft.date)
                TextField("Odometer (\(measurements.distanceUnit.abbreviation))", text: $draft.odometer)
                    .keyboardType(.decimalPad)
                TextField("\(measurements.fuelVolumeUnit.rawValue)", text: $draft.gallons)
                    .keyboardType(.decimalPad)
                TextField("Price per \(measurements.fuelVolumeUnit.abbreviation)", text: $draft.pricePerGallon)
                    .keyboardType(.decimalPad)
                TextField("Location", text: $draft.location)
                Toggle("Auto Logged Location", isOn: Binding(
                    get: { draft.autoLoggedLocation },
                    set: { newValue in
                        draft.autoLoggedLocation = newValue

                        if newValue {
                            Task {
                                await lookupCurrentLocation()
                            }
                        }
                    }
                ))

                if isLookingUpLocation {
                    HStack {
                        ProgressView()
                        Text("Identifying current location")
                            .foregroundStyle(.secondary)
                    }
                }

                if let locationError {
                    Text(locationError)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Log Fill-Up")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.vehicle == nil)
                }
            }
            .task {
                guard draft.autoLoggedLocation, draft.location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }

                await lookupCurrentLocation()
            }
        }
    }

    private func lookupCurrentLocation() async {
        isLookingUpLocation = true
        locationError = nil

        do {
            draft.location = try await locationLookupService.currentPlaceName()
        } catch {
            locationError = error.localizedDescription
        }

        isLookingUpLocation = false
    }
}

private struct TripForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TripDraft

    let vehicles: [Vehicle]
    let measurements: MeasurementPreferences
    let onSave: (TripDraft) -> Void

    init(vehicles: [Vehicle], defaultVehicle: Vehicle?, measurements: MeasurementPreferences, onSave: @escaping (TripDraft) -> Void) {
        self.vehicles = vehicles
        self.measurements = measurements
        self.onSave = onSave
        _draft = State(initialValue: TripDraft(vehicle: defaultVehicle))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Trip name", text: $draft.name)
                Picker("Vehicle", selection: $draft.vehicle) {
                    ForEach(vehicles, id: \.objectID) { vehicle in
                        Text(vehicle.displayName).tag(Optional(vehicle))
                    }
                }
                Picker("Trip type", selection: $draft.tripType) {
                    ForEach(TripType.allCases) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                DatePicker("Start", selection: $draft.startDate)
                DatePicker("End", selection: $draft.endDate)
                TextField("Start location", text: $draft.startLocation)
                TextField("End location", text: $draft.endLocation)
                TextField("Route", text: $draft.route)
                TextField("Distance (\(measurements.distanceUnit.abbreviation))", text: $draft.distance)
                    .keyboardType(.decimalPad)
                TextField("Average speed (\(measurements.distanceUnit.speedAbbreviation))", text: $draft.averageSpeed)
                    .keyboardType(.decimalPad)
            }
            .navigationTitle("Start Trip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.vehicle == nil || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct UpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SubscriptionStore.self) private var subscriptionStore
    @State private var purchasingProductID: String?
    @State private var purchaseError: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("FuelAid Pro")
                            .font(.title2.weight(.semibold))
                        Text("Unlock unlimited vehicles and the advanced tools planned for paid subscribers.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Included") {
                    ForEach(PremiumFeature.allCases) { feature in
                        Label(feature.rawValue, systemImage: feature.systemImage)
                    }
                }

                Section("Upgrade Options") {
                    if subscriptionStore.products.isEmpty {
                        ContentUnavailableView(
                            "Subscriptions Not Configured",
                            systemImage: "cart.badge.questionmark",
                            description: Text("Add the FuelAid Pro products in App Store Connect or a StoreKit test configuration.")
                        )
                    } else {
                        ForEach(FuelAidPurchaseOption.allCases) { option in
                            PurchaseOptionRow(
                                option: option,
                                product: subscriptionStore.product(for: option),
                                isPurchasing: purchasingProductID == option.productID
                            ) {
                                await purchase(option)
                            }
                        }
                    }
                }

                if let purchaseError {
                    Section {
                        Text(purchaseError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Upgrade")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Restore") {
                        Task {
                            try? await AppStore.sync()
                            await subscriptionStore.refreshEntitlements()
                        }
                    }
                }
            }
        }
    }

    private func purchase(_ option: FuelAidPurchaseOption) async {
        purchasingProductID = option.productID
        purchaseError = nil

        do {
            try await subscriptionStore.purchase(option)
        } catch {
            purchaseError = error.localizedDescription
        }

        purchasingProductID = nil
    }
}

private struct PurchaseOptionRow: View {
    let option: FuelAidPurchaseOption
    let product: Product?
    let isPurchasing: Bool
    let purchase: () async -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.title)
                    .font(.headline)
                Text(product?.displayPrice ?? "Unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task {
                    await purchase()
                }
            } label: {
                if isPurchasing {
                    ProgressView()
                } else {
                    Text("Buy")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(product == nil || isPurchasing)
        }
        .padding(.vertical, 4)
    }
}

private struct VehicleDraft {
    var name = ""
    var make = ""
    var model = ""
    var year = ""
    var vin = ""
    var licensePlate = ""
    var recommendedTirePressure = ""
    var isDefault = false

    init() { }

    init(vehicle: Vehicle) {
        name = vehicle.name ?? ""
        make = vehicle.make ?? ""
        model = vehicle.model ?? ""
        year = vehicle.year == 0 ? "" : String(vehicle.year)
        vin = vehicle.vin ?? ""
        licensePlate = vehicle.licensePlate ?? ""
        recommendedTirePressure = vehicle.recommendedTirePressure == 0 ? "" : String(vehicle.recommendedTirePressure)
        isDefault = vehicle.isDefault
    }
}

private struct FillUpDraft {
    var vehicle: Vehicle?
    var date = Date()
    var odometer = ""
    var gallons = ""
    var pricePerGallon = ""
    var location = ""
    var autoLoggedLocation: Bool
}

private struct TripDraft {
    var vehicle: Vehicle?
    var name = ""
    var startDate = Date()
    var endDate = Date()
    var startLocation = ""
    var endLocation = ""
    var route = ""
    var distance = ""
    var averageSpeed = ""
    var tripType = TripType.standard
}

private func apply(_ draft: VehicleDraft, to vehicle: Vehicle) {
    vehicle.name = draft.name
    vehicle.make = draft.make
    vehicle.model = draft.model
    vehicle.year = Int64(draft.year) ?? 0
    vehicle.vin = draft.vin
    vehicle.licensePlate = draft.licensePlate
    vehicle.recommendedTirePressure = Double(draft.recommendedTirePressure) ?? 0
}

private extension Vehicle {
    var displayName: String {
        name?.nilIfEmpty ?? [make, model].compactMap { $0?.nilIfEmpty }.joined(separator: " ").nilIfEmpty ?? "Vehicle"
    }

    var isArchivedForDisplay: Bool {
        value(forKey: "isArchived") as? Bool ?? false
    }

    var archivedAtForDisplay: Date? {
        value(forKey: "archivedAt") as? Date
    }
}

private extension AppPreference {
    var measurementPreferences: MeasurementPreferences {
        MeasurementPreferences(
            fuelVolumeUnit: FuelVolumeUnit(rawValue: value(forKey: "fuelVolumeUnit") as? String ?? "") ?? .gallons,
            distanceUnit: DistanceUnit(rawValue: value(forKey: "distanceUnit") as? String ?? "") ?? .miles
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

#Preview {
    ContentView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
        .environment(SubscriptionStore())
}
