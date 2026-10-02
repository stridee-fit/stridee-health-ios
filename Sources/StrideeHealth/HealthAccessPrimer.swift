import SwiftUI

/// The screen to show *before* the HealthKit permission sheet.
///
/// Apple's sheet appears once per data type, ever, and says nothing about why
/// your app wants the data. A user who meets it cold tends to turn everything
/// off, and iOS will never show it again — the only way back is Settings. A
/// screen of your own first, saying what is read and what it is for, is what
/// Apple's Human Interface Guidelines recommend and what gets the switches
/// turned on.
///
/// ```swift
/// .sheet(isPresented: $showPrimer) {
///     HealthAccessPrimer(onFinished: { showPrimer = false },
///                        onNotNow: { showPrimer = false })
/// }
/// ```
///
/// By default, Continue runs ``HealthSync/connect(requestingAuthorization:)``,
/// which shows Apple's sheet and starts syncing. Pass `action:` to do
/// something else — ``HealthSync/requestAuthorization(for:)`` alone, say, to
/// ask now and connect later.
///
/// The words are yours: ``Copy/english`` is a starting point, and every field
/// can be replaced or localized.
public struct HealthAccessPrimer: View {

    /// Everything the screen says.
    public struct Copy {
        public var title: String
        public var message: String
        public var rows: [Row]
        public var continueTitle: String
        public var notNowTitle: String
        /// Shown under the buttons when `action` throws.
        public var failureMessage: String

        public init(
            title: String,
            message: String,
            rows: [Row],
            continueTitle: String,
            notNowTitle: String,
            failureMessage: String
        ) {
            self.title = title
            self.message = message
            self.rows = rows
            self.continueTitle = continueTitle
            self.notNowTitle = notNowTitle
            self.failureMessage = failureMessage
        }

        /// A starting point in English. Replace it, or build a `Copy` from your
        /// own localized strings — the SDK ships no translations.
        public static let english = Copy(
            title: "Connect Apple Health",
            message: "Your workouts and recovery data sync automatically, so you never have to log them twice.",
            rows: [
                Row(systemImage: "figure.run", title: "Workouts",
                    detail: "Routes, heart rate, pace and power from every workout."),
                Row(systemImage: "bed.double.fill", title: "Sleep & recovery",
                    detail: "Sleep stages, HRV and resting heart rate."),
                Row(systemImage: "lock.fill", title: "Read-only",
                    detail: "Nothing is ever written to Apple Health. Turn it off any time in Settings."),
            ],
            continueTitle: "Continue",
            notNowTitle: "Not now",
            failureMessage: "That didn't work. Check your connection and try again."
        )
    }

    public struct Row: Identifiable {
        public let id = UUID()
        public var systemImage: String
        public var title: String
        public var detail: String

        public init(systemImage: String, title: String, detail: String) {
            self.systemImage = systemImage
            self.title = title
            self.detail = detail
        }
    }

    private let copy: Copy
    private let action: @MainActor () async throws -> Void
    private let onFinished: @MainActor () -> Void
    private let onNotNow: @MainActor () -> Void

    @State private var isWorking = false
    @State private var failed = false

    /// - Parameters:
    ///   - copy: What the screen says.
    ///   - action: Run on Continue. Defaults to connecting.
    ///   - onFinished: Called once `action` returns — dismiss here.
    ///   - onNotNow: Called on Not now — dismiss, and ask again some other day.
    public init(
        copy: Copy = .english,
        action: @escaping @MainActor () async throws -> Void = { try await HealthSync.shared.connect() },
        onFinished: @escaping @MainActor () -> Void,
        onNotNow: @escaping @MainActor () -> Void
    ) {
        self.copy = copy
        self.action = action
        self.onFinished = onFinished
        self.onNotNow = onNotNow
    }

    public var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "heart.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Color.pink.gradient))
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(verbatim: copy.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text(verbatim: copy.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(copy.rows) { row in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: row.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.pink)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: row.title).font(.subheadline.weight(.semibold))
                            Text(verbatim: row.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button {
                    Task { await run() }
                } label: {
                    ZStack {
                        Text(verbatim: copy.continueTitle).opacity(isWorking ? 0 : 1)
                        if isWorking { ProgressView() }
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .disabled(isWorking)

                Button {
                    onNotNow()
                } label: {
                    Text(verbatim: copy.notNowTitle).frame(maxWidth: .infinity)
                }
                .disabled(isWorking)

                if failed {
                    Text(verbatim: copy.failureMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(24)
    }

    @MainActor
    private func run() async {
        isWorking = true
        failed = false
        defer { isWorking = false }
        do {
            try await action()
            onFinished()
        } catch {
            failed = true
        }
    }
}

#Preview {
    HealthAccessPrimer(action: {}, onFinished: {}, onNotNow: {})
}
