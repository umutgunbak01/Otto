import SwiftUI

// MARK: - Date Dropdown Picker

struct DateDropdownPicker: View {
    @Binding var date: Date

    @State private var selectedDay: Int = 1
    @State private var selectedMonth: Int = 1
    @State private var selectedYear: Int = 2026

    private let months = ["January", "February", "March", "April", "May", "June",
                          "July", "August", "September", "October", "November", "December"]

    private var years: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array((currentYear - 1)...(currentYear + 5))
    }

    private var daysInMonth: Int {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = selectedYear
        components.month = selectedMonth
        if let date = calendar.date(from: components),
           let range = calendar.range(of: .day, in: .month, for: date) {
            return range.count
        }
        return 31
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Day picker
            dropdownMenu(
                selection: $selectedDay,
                options: Array(1...daysInMonth),
                label: { "\($0)" },
                width: 60
            )

            // Month picker
            dropdownMenu(
                selection: $selectedMonth,
                options: Array(1...12),
                label: { months[$0 - 1] },
                width: 110
            )

            // Year picker
            dropdownMenu(
                selection: $selectedYear,
                options: years,
                label: { "\($0)" },
                width: 80
            )
        }
        .onAppear { loadFromDate() }
        .onChange(of: date) { loadFromDate() }
        .onChange(of: selectedDay) { updateDate() }
        .onChange(of: selectedMonth) { updateDate() }
        .onChange(of: selectedYear) { updateDate() }
    }

    private func dropdownMenu<T: Hashable>(
        selection: Binding<T>,
        options: [T],
        label: @escaping (T) -> String,
        width: CGFloat
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    HStack {
                        Text(label(option))
                        if selection.wrappedValue == option {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(label(selection.wrappedValue))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.borderSubtle.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Colors.hoverTint, lineWidth: 1)
            )
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }

    private func loadFromDate() {
        let calendar = Calendar.current
        selectedDay = calendar.component(.day, from: date)
        selectedMonth = calendar.component(.month, from: date)
        selectedYear = calendar.component(.year, from: date)
    }

    private func updateDate() {
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = selectedYear
        components.month = selectedMonth
        components.day = min(selectedDay, daysInMonth)
        components.hour = calendar.component(.hour, from: date)
        components.minute = calendar.component(.minute, from: date)

        if let newDate = calendar.date(from: components) {
            date = newDate
        }
    }
}

// MARK: - Time Dropdown Picker

struct TimeDropdownPicker: View {
    @Binding var date: Date
    @Binding var hasTime: Bool

    @State private var selectedHour: Int = 9
    @State private var selectedMinute: Int = 0

    private let hours = Array(0...23)
    private let minutes = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            // Time toggle
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    hasTime.toggle()
                    if hasTime {
                        // Set to 9:00 AM by default when enabling
                        selectedHour = 9
                        selectedMinute = 0
                        updateDate()
                    } else {
                        // Clear time (set to midnight)
                        clearTime()
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: hasTime ? "clock.fill" : "clock")
                        .font(.system(size: 12))
                    Text(hasTime ? "Time set" : "Add time")
                        .font(Theme.Typography.caption)
                }
                .foregroundStyle(hasTime ? Theme.Colors.accent : Theme.Colors.secondaryText)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(hasTime ? Theme.Colors.accent.opacity(0.1) : Theme.Colors.borderSubtle.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(hasTime ? Theme.Colors.accent.opacity(0.2) : Theme.Colors.hoverTint, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            if hasTime {
                // Hour picker
                dropdownMenu(
                    selection: $selectedHour,
                    options: hours,
                    label: { String(format: "%02d", $0) },
                    width: 60
                )

                Text(":")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)

                // Minute picker
                dropdownMenu(
                    selection: $selectedMinute,
                    options: minutes,
                    label: { String(format: "%02d", $0) },
                    width: 60
                )
            }
        }
        .onAppear { loadFromDate() }
        .onChange(of: date) { loadFromDate() }
        .onChange(of: selectedHour) { updateDate() }
        .onChange(of: selectedMinute) { updateDate() }
    }

    private func dropdownMenu(
        selection: Binding<Int>,
        options: [Int],
        label: @escaping (Int) -> String,
        width: CGFloat
    ) -> some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection.wrappedValue = option
                } label: {
                    HStack {
                        Text(label(option))
                        if selection.wrappedValue == option {
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(label(selection.wrappedValue))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.borderSubtle.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.Colors.hoverTint, lineWidth: 1)
            )
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }

    private func loadFromDate() {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)

        selectedHour = hour
        // Snap to nearest 5-minute interval
        selectedMinute = (minute / 5) * 5

        // Check if time is set (not midnight)
        hasTime = !(hour == 0 && minute == 0)
    }

    private func updateDate() {
        guard hasTime else { return }

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = selectedHour
        components.minute = selectedMinute

        if let newDate = calendar.date(from: components) {
            date = newDate
        }
    }

    private func clearTime() {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 0
        components.minute = 0

        if let newDate = calendar.date(from: components) {
            date = newDate
        }
    }
}

// MARK: - Combined Date Time Picker

struct DateTimeDropdownPicker: View {
    @Binding var date: Date
    @State private var hasTime: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Date row
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 16)

                DateDropdownPicker(date: $date)
            }

            // Time row
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "clock")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .frame(width: 16)

                TimeDropdownPicker(date: $date, hasTime: $hasTime)
            }
        }
    }
}

// MARK: - Quick Date Buttons

struct QuickDateButtons: View {
    @Binding var date: Date

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            quickButton("Today", date: Date(), icon: "sun.max")
            quickButton("Tomorrow", date: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date(), icon: "sunrise")
            quickButton("Next Week", date: Calendar.current.date(byAdding: .weekOfYear, value: 1, to: Date()) ?? Date(), icon: "calendar")
        }
    }

    private func quickButton(_ label: String, date targetDate: Date, icon: String) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(date, inSameDayAs: targetDate)

        return Button {
            // Preserve time if set
            let currentHour = calendar.component(.hour, from: date)
            let currentMinute = calendar.component(.minute, from: date)

            var components = calendar.dateComponents([.year, .month, .day], from: targetDate)
            components.hour = currentHour
            components.minute = currentMinute

            if let newDate = calendar.date(from: components) {
                date = newDate
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(Theme.Typography.caption)
            }
            .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.secondaryText)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isSelected ? Theme.Colors.accent.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(isSelected ? Theme.Colors.accent.opacity(0.2) : Theme.Colors.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: Theme.Spacing.xl) {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Date & Time Picker")
                .font(Theme.Typography.headline)
            DateTimeDropdownPicker(date: .constant(Date()))
        }

        Divider()

        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Quick Date Buttons")
                .font(Theme.Typography.headline)
            QuickDateButtons(date: .constant(Date()))
        }
    }
    .padding(Theme.Spacing.xl)
    .frame(width: 500)
}
