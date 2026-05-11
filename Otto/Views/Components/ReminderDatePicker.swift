import SwiftUI

// MARK: - Reminder Date Picker (always has a date)

struct ReminderDatePicker: View {
    @Binding var date: Date
    @State private var showingPicker: Bool = false
    @State private var tempDate: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Date row - clickable
            Button {
                tempDate = date
                showingPicker.toggle()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "calendar")
                        .font(.system(size: 14))
                        .foregroundStyle(dateColor)
                        .frame(width: 20)

                    Text(formatDisplayDate(date))
                        .font(Theme.Typography.body)
                        .foregroundStyle(dateColor)

                    Text(formatTime(date))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.secondaryText)

                    Spacer()

                    Image(systemName: showingPicker ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(showingPicker ? Theme.Colors.accent.opacity(0.05) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(showingPicker ? Theme.Colors.accent.opacity(0.2) : Color.clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            // Expanded picker
            if showingPicker {
                ReminderDatePickerPopover(
                    date: $tempDate,
                    onSelect: { selectedDate in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            date = selectedDate
                            showingPicker = false
                        }
                    }
                )
                .padding(.top, Theme.Spacing.sm)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showingPicker)
    }

    private var dateColor: Color {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateDay = calendar.startOfDay(for: date)

        if dateDay < today {
            return Theme.Colors.priorityUrgent // Overdue
        } else if dateDay == today {
            return Theme.Colors.personal // Today - green
        } else if dateDay == calendar.date(byAdding: .day, value: 1, to: today) {
            return Theme.Colors.priorityHigh // Tomorrow - orange
        }
        return Theme.Colors.text
    }

    private func formatDisplayDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dateDay = calendar.startOfDay(for: date)

        if dateDay == today {
            return "Today"
        } else if dateDay == calendar.date(byAdding: .day, value: 1, to: today) {
            return "Tomorrow"
        } else if dateDay == calendar.date(byAdding: .day, value: -1, to: today) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "d MMM"
            return formatter.string(from: date)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Reminder Date Picker Popover

struct ReminderDatePickerPopover: View {
    @Binding var date: Date
    let onSelect: (Date) -> Void

    @State private var selectedHour: Int = 9
    @State private var selectedMinute: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Quick options
            quickOptionsSection

            OttoDivider()
                .padding(.vertical, Theme.Spacing.sm)

            // Mini calendar
            miniCalendarSection

            OttoDivider()
                .padding(.vertical, Theme.Spacing.sm)

            // Time section (always visible for reminders)
            timeSection

            // Action buttons
            HStack(spacing: Theme.Spacing.md) {
                Spacer()

                Button("Done") {
                    let calendar = Calendar.current
                    var components = calendar.dateComponents([.year, .month, .day], from: date)
                    components.hour = selectedHour
                    components.minute = selectedMinute
                    if let newDate = calendar.date(from: components) {
                        onSelect(newDate)
                    } else {
                        onSelect(date)
                    }
                }
                .buttonStyle(.plain)
                .font(Theme.Typography.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.Colors.accent)
            }
            .padding(.top, Theme.Spacing.md)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Colors.secondaryBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(Theme.Colors.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
        .onAppear {
            let calendar = Calendar.current
            selectedHour = calendar.component(.hour, from: date)
            selectedMinute = calendar.component(.minute, from: date)
        }
    }

    // MARK: - Quick Options

    private var quickOptionsSection: some View {
        VStack(spacing: 2) {
            quickOptionRow(
                icon: "clock.badge.exclamationmark",
                iconColor: Theme.Colors.priorityUrgent,
                title: "In 30 minutes",
                subtitle: formatTime(Date().addingTimeInterval(30 * 60)),
                action: { selectDate(Date().addingTimeInterval(30 * 60)) }
            )

            quickOptionRow(
                icon: "clock",
                iconColor: Theme.Colors.priorityHigh,
                title: "In 1 hour",
                subtitle: formatTime(Date().addingTimeInterval(60 * 60)),
                action: { selectDate(Date().addingTimeInterval(60 * 60)) }
            )

            quickOptionRow(
                icon: "clock.arrow.2.circlepath",
                iconColor: Theme.Colors.work,
                title: "In 3 hours",
                subtitle: formatTime(Date().addingTimeInterval(3 * 60 * 60)),
                action: { selectDate(Date().addingTimeInterval(3 * 60 * 60)) }
            )

            quickOptionRow(
                icon: "sunrise",
                iconColor: Theme.Colors.personal,
                title: "Tomorrow morning",
                subtitle: "09:00",
                action: { selectTomorrowAt(hour: 9, minute: 0) }
            )

            quickOptionRow(
                icon: "sun.max",
                iconColor: Theme.Colors.hobby,
                title: "Tomorrow afternoon",
                subtitle: "14:00",
                action: { selectTomorrowAt(hour: 14, minute: 0) }
            )
        }
    }

    private func quickOptionRow(icon: String, iconColor: Color, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)

                Spacer()

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mini Calendar

    private var miniCalendarSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            // Month navigation
            HStack {
                Text(monthYearString(date))
                    .font(Theme.Typography.headline)
                    .foregroundStyle(Theme.Colors.text)

                Spacer()

                HStack(spacing: Theme.Spacing.xs) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            date = Calendar.current.date(byAdding: .month, value: -1, to: date) ?? date
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            date = Date()
                        }
                    } label: {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 6))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            date = Calendar.current.date(byAdding: .month, value: 1, to: date) ?? date
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.Colors.secondaryText)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Weekday headers
            HStack(spacing: 0) {
                ForEach(["M", "T", "W", "T", "F", "S", "S"], id: \.self) { day in
                    Text(day)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }

            // Calendar grid
            let days = calendarDays()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                ForEach(days, id: \.self) { day in
                    if let day = day {
                        calendarDayButton(day)
                    } else {
                        Text("")
                            .frame(height: 28)
                    }
                }
            }
        }
    }

    private func calendarDayButton(_ day: Date) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(day, inSameDayAs: date)
        let isToday = calendar.isDateInToday(day)
        let dayNumber = calendar.component(.day, from: day)

        return Button {
            withAnimation(.easeInOut(duration: 0.1)) {
                // Preserve time when selecting a new date
                var components = calendar.dateComponents([.year, .month, .day], from: day)
                components.hour = selectedHour
                components.minute = selectedMinute
                if let newDate = calendar.date(from: components) {
                    date = newDate
                }
            }
        } label: {
            Text("\(dayNumber)")
                .font(Theme.Typography.caption)
                .fontWeight(isToday ? .bold : .regular)
                .foregroundStyle(
                    isSelected ? .white :
                    isToday ? Theme.Colors.accent :
                    Theme.Colors.text
                )
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isSelected ? Theme.Colors.accent : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Time Section

    private var timeSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "clock")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 20)

                Text("Time")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.text)

                Spacer()

                // Hour dropdown
                timeDropdown(
                    selection: $selectedHour,
                    options: Array(0..<24),
                    label: { String(format: "%02d", $0) }
                )

                Text(":")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)

                // Minute dropdown
                timeDropdown(
                    selection: $selectedMinute,
                    options: [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55],
                    label: { String(format: "%02d", $0) }
                )
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.sm)
        }
    }

    // MARK: - Time Dropdown Helper

    private func timeDropdown(
        selection: Binding<Int>,
        options: [Int],
        label: @escaping (Int) -> String
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

    // MARK: - Helpers

    private func selectDate(_ newDate: Date) {
        onSelect(newDate)
    }

    private func selectTomorrowAt(hour: Int, minute: Int) {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) else { return }
        var components = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        components.hour = hour
        components.minute = minute
        if let finalDate = calendar.date(from: components) {
            onSelect(finalDate)
        }
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func monthYearString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
    }

    private func calendarDays() -> [Date?] {
        let calendar = Calendar.current

        // Get first day of the month
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let firstOfMonth = calendar.date(from: components) else { return [] }

        // Get the weekday of the first day (1 = Sunday, 2 = Monday, ...)
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        // Convert to Monday-based (0 = Monday, 6 = Sunday)
        let offset = (firstWeekday + 5) % 7

        // Get number of days in month
        guard let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else { return [] }
        let daysInMonth = range.count

        var days: [Date?] = []

        // Add empty slots for days before the first
        for _ in 0..<offset {
            days.append(nil)
        }

        // Add all days in the month
        for day in 1...daysInMonth {
            var dayComponents = components
            dayComponents.day = day
            if let dayDate = calendar.date(from: dayComponents) {
                days.append(dayDate)
            }
        }

        // Add days from next month to fill the grid
        let remainingSlots = (7 - (days.count % 7)) % 7
        if let lastDay = calendar.date(from: DateComponents(year: components.year, month: components.month, day: daysInMonth)) {
            for i in 1...remainingSlots {
                if let nextDay = calendar.date(byAdding: .day, value: i, to: lastDay) {
                    days.append(nextDay)
                }
            }
        }

        return days
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: Theme.Spacing.xl) {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Reminder Date Picker")
                .font(Theme.Typography.headline)
            ReminderDatePicker(date: .constant(Date().addingTimeInterval(3600)))
        }
    }
    .padding(Theme.Spacing.xl)
    .frame(width: 350)
}
