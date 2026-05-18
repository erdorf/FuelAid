//
//  ContentView.swift
//  FuelAid
//
//  Created by ERIC DIEVENDORF on 5/17/26.
//

import CoreData
import StoreKit
import SwiftUI

enum TripType: String, CaseIterable, Identifiable {
    case standard = "Standard"
    case business = "Business"
    case towing = "Towing"

    var id: String { rawValue }
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

    private var defaultVehicle: Vehicle? {
        vehicles.first(where: { $0.isDefault }) ?? vehicles.first
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    QuickFuelCard(defaultVehicle: defaultVehicle, addAction: { showingFillUpForm = true })
                    MPGTrendCard(vehicle: defaultVehicle, fillUps: Array(fillUps))
                    PlanStatusCard(vehicleCount: vehicles.count)
                    DashboardLinks(showUpgrade: { showingUpgrade = true })
                    RecentActivityCard(fillUps: Array(fillUps.prefix(3)), trips: Array(trips.prefix(3)))
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("FuelAid")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add Vehicle", systemImage: "car") { showVehicleEntry() }
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
                FillUpForm(vehicles: Array(vehicles), defaultVehicle: defaultVehicle, autoLogLocation: preferences.first?.autoLogFillUpLocations ?? true) {
                    saveFillUp($0)
                }
            }
            .sheet(isPresented: $showingTripForm) {
                TripForm(vehicles: Array(vehicles), defaultVehicle: defaultVehicle) {
                    saveTrip($0)
                }
            }
            .sheet(isPresented: $showingUpgrade) {
                UpgradeView()
            }
            .onAppear(perform: ensurePreferencesExist)
        }
    }

    private func showVehicleEntry() {
        if subscriptionStore.canAddVehicle(currentCount: vehicles.count) {
            showingVehicleForm = true
        } else {
            showingUpgrade = true
        }
    }

    private func saveVehicle(_ draft: VehicleDraft) {
        guard subscriptionStore.canAddVehicle(currentCount: vehicles.count) else {
            showingUpgrade = true
            return
        }

        let vehicle = Vehicle(context: viewContext)
        assignToPrivateStore(vehicle)
        vehicle.id = UUID()
        vehicle.createdAt = Date()
        vehicle.name = draft.name
        vehicle.make = draft.make
        vehicle.model = draft.model
        vehicle.year = Int64(draft.year) ?? 0
        vehicle.vin = draft.vin
        vehicle.licensePlate = draft.licensePlate
        vehicle.recommendedTirePressure = Double(draft.recommendedTirePressure) ?? 0
        vehicle.isDefault = vehicles.isEmpty || draft.isDefault

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
        fillUp.odometer = Double(draft.odometer) ?? 0
        fillUp.gallons = Double(draft.gallons) ?? 0
        fillUp.pricePerGallon = Double(draft.pricePerGallon) ?? 0
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
        trip.distance = Double(draft.distance) ?? 0
        trip.averageSpeed = Double(draft.averageSpeed) ?? 0
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
    let defaultVehicle: Vehicle?
    let addAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(defaultVehicle?.displayName ?? "No Default Vehicle")
                        .font(.title3.weight(.semibold))
                    Text("Quick fuel entry")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: addAction) {
                    Label("Log", systemImage: "fuelpump.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(defaultVehicle == nil)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MPGTrendCard: View {
    let vehicle: Vehicle?
    let fillUps: [FillUp]

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
            guard miles > 0, current.gallons > 0 else { return nil }
            return miles / current.gallons
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MPG Trend")
                    .font(.headline)
                Spacer()
                Text(points.last.map { "\($0, specifier: "%.1f") MPG" } ?? "No data")
                    .foregroundStyle(.secondary)
            }

            MPGLineGraph(points: points)
                .frame(height: 140)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct MPGLineGraph: View {
    let points: [Double]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard points.count > 1, let minValue = points.min(), let maxValue = points.max() else { return }

                let width = proxy.size.width
                let height = proxy.size.height
                let range = max(maxValue - minValue, 1)

                for index in points.indices {
                    let x = width * CGFloat(index) / CGFloat(points.count - 1)
                    let y = height - ((points[index] - minValue) / range * height)
                    let point = CGPoint(x: x, y: y)

                    if index == points.startIndex {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct RecentActivityCard: View {
    let fillUps: [FillUp]
    let trips: [Trip]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            if fillUps.isEmpty && trips.isEmpty {
                Text("No fuel or trip records yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(fillUps, id: \.objectID) { fillUp in
                    Label("\(fillUp.vehicle?.displayName ?? "Vehicle") fuel: \(fillUp.gallons, specifier: "%.1f") gal", systemImage: "fuelpump")
                }

                ForEach(trips, id: \.objectID) { trip in
                    Label("\(trip.name?.nilIfEmpty ?? "Trip"): \(trip.distance, specifier: "%.1f") mi", systemImage: "map")
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

    var body: some View {
        List {
            ForEach(vehicles, id: \.objectID) { vehicle in
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

            if let limit = subscriptionStore.vehicleLimit {
                Section {
                    Label("Free version supports up to \(limit) vehicles", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Vehicles")
    }
}

private struct TripListView: View {
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Trip.startDate, ascending: false)], animation: .default)
    private var trips: FetchedResults<Trip>

    var body: some View {
        List(trips, id: \.objectID) { trip in
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.name?.nilIfEmpty ?? "Trip")
                    .font(.headline)
                Text("\(trip.vehicle?.displayName ?? "Vehicle") - \(trip.tripType ?? TripType.standard.rawValue)")
                    .foregroundStyle(.secondary)
                Text("\(trip.startLocation?.nilIfEmpty ?? "Start") to \(trip.endLocation?.nilIfEmpty ?? "End")")
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

        return "\(mileage.formatted(.number.precision(.fractionLength(1)))) mi"
    }
}

private struct SettingsView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(SubscriptionStore.self) private var subscriptionStore
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \AppPreference.createdAt, ascending: true)], animation: .default)
    private var preferences: FetchedResults<AppPreference>

    var body: some View {
        Form {
            Section("Fuel Logging") {
                Toggle("Auto-log fill-up locations", isOn: Binding(
                    get: { preferences.first?.autoLogFillUpLocations ?? true },
                    set: { newValue in
                        preferences.first?.autoLogFillUpLocations = newValue
                        try? viewContext.save()
                    }
                ))
            }

            Section("Plan") {
                LabeledContent("Current plan", value: subscriptionStore.planName)
                NavigationLink("Upgrade options") {
                    UpgradeView()
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
    }
}

private struct VehicleForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = VehicleDraft()

    let onSave: (VehicleDraft) -> Void

    var body: some View {
        NavigationStack {
            Form {
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

private struct FillUpForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: FillUpDraft

    let vehicles: [Vehicle]
    let onSave: (FillUpDraft) -> Void

    init(vehicles: [Vehicle], defaultVehicle: Vehicle?, autoLogLocation: Bool, onSave: @escaping (FillUpDraft) -> Void) {
        self.vehicles = vehicles
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
                TextField("Odometer", text: $draft.odometer)
                    .keyboardType(.decimalPad)
                TextField("Gallons", text: $draft.gallons)
                    .keyboardType(.decimalPad)
                TextField("Price per gallon", text: $draft.pricePerGallon)
                    .keyboardType(.decimalPad)
                TextField("Location", text: $draft.location)
                Toggle("Auto-logged location", isOn: $draft.autoLoggedLocation)
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
        }
    }
}

private struct TripForm: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TripDraft

    let vehicles: [Vehicle]
    let onSave: (TripDraft) -> Void

    init(vehicles: [Vehicle], defaultVehicle: Vehicle?, onSave: @escaping (TripDraft) -> Void) {
        self.vehicles = vehicles
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
                TextField("Distance", text: $draft.distance)
                    .keyboardType(.decimalPad)
                TextField("Average speed", text: $draft.averageSpeed)
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

                Section("Subscription") {
                    if subscriptionStore.products.isEmpty {
                        ContentUnavailableView(
                            "Subscriptions Not Configured",
                            systemImage: "cart.badge.questionmark",
                            description: Text("Add the FuelAid Pro products in App Store Connect or a StoreKit test configuration.")
                        )
                    } else {
                        StoreView(ids: SubscriptionStore.productIDs)
                            .storeButton(.visible, for: .restorePurchases)
                    }
                }
            }
            .navigationTitle("Upgrade")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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

private extension Vehicle {
    var displayName: String {
        name?.nilIfEmpty ?? [make, model].compactMap { $0?.nilIfEmpty }.joined(separator: " ").nilIfEmpty ?? "Vehicle"
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
