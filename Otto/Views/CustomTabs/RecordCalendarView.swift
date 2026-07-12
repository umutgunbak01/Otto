import SwiftUI

/// Month-grid calendar over one collection's records, placed by a date
/// column (`dateFieldOverride` → the collection's configured date field →
/// its first date column). Works as a full tab layout and embedded in a
/// dashboard `records` block; clicking a record chip opens the editor.
struct RecordCalendarView: View {
    let tab: CustomTabDefinition
    let collection: TabCollection
    let records: [CustomRecord]
    let embedded: Bool
    /// records-block `date_field` (key or name); nil → collection default.
    var dateFieldOverride: String? = nil
    let onOpen: (CustomRecord) -> Void
    let onDelete: (CustomRecord) -> Void

    /// First day of the displayed month (midnight local).
    @State private var displayedMonth: Date = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()

    private var calendar: Calendar { Calendar.current }

    private var dateField: CustomFieldDefinition? {
        if let raw = dateFieldOverride?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
            let key = CustomTabSlug.slugify(raw)
            if let field = collection.fields.first(where: {
                $0.kind == .date && ($0.name.caseInsensitiveCompare(raw) == .orderedSame || CustomTabSlug.slugify($0.name) == key)
            }) {
                return field
            }
        }
        return collection.dateField
    }

    var body: some View {
        if let field = dateField {
            calendarBody(field: field)
        } else {
            VStack(spacing: 8) {
                Text("Calendar view needs a date column on \"\(collection.name)\".")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Colors.textDim)
                Text("Add one in Edit tab, or ask Otto to add it.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity)
            .padding(Theme.Spacing.lg)
        }
    }

    // MARK: - Grid data

    private func recordDay(_ record: CustomRecord, field: CustomFieldDefinition) -> Date? {
        guard case .date(let d)? = record.values[field.id] else { return nil }
        return calendar.startOfDay(for: d)
    }

    private struct DaySlot: Identifiable {
        let id: Int
        let date: Date?          // nil = leading/trailing filler cell
        let records: [CustomRecord]
    }

    private func slots(field: CustomFieldDefinition) -> [DaySlot] {
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let dayCount = calendar.range(of: .day, in: .month, for: displayedMonth)?.count else { return [] }

        var byDay: [Date: [CustomRecord]] = [:]
        for record in records {
            if let day = recordDay(record, field: field) {
                byDay[day, default: []].append(record)
            }
        }

        // Column index of day 1, honoring the user's firstWeekday setting.
        let firstWeekdayOfMonth = calendar.component(.weekday, from: monthInterval.start)
        let leading = (firstWeekdayOfMonth - calendar.firstWeekday + 7) % 7

        var out: [DaySlot] = []
        for i in 0..<leading {
            out.append(DaySlot(id: i, date: nil, records: []))
        }
        for day in 0..<dayCount {
            let date = calendar.date(byAdding: .day, value: day, to: monthInterval.start)!
            out.append(DaySlot(id: leading + day, date: date, records: byDay[calendar.startOfDay(for: date)] ?? []))
        }
        while out.count % 7 != 0 {
            out.append(DaySlot(id: out.count, date: nil, records: []))
        }
        return out
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private func undatedCount(field: CustomFieldDefinition) -> Int {
        records.filter { recordDay($0, field: field) == nil }.count
    }

    // MARK: - Body

    private func calendarBody(field: CustomFieldDefinition) -> some View {
        let slots = slots(field: field)
        let undated = undatedCount(field: field)
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            monthHeader

            HStack(spacing: 0) {
                ForEach(weekdaySymbols.indices, id: \.self) { i in
                    Text(weekdaySymbols[i].uppercased())
                        .font(Theme.Typography.label)
                        .tracking(Theme.Tracking.xwide)
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(slots) { slot in
                    dayCell(slot)
                }
            }

            if undated > 0 {
                Text("\(undated) record\(undated == 1 ? "" : "s") without a \(field.name) date — visible in other views.")
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Colors.tertiaryText)
            }
        }
        .padding(embedded ? 0 : Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: embedded ? nil : .infinity, alignment: .topLeading)
    }

    private var monthHeader: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Colors.text)

            Spacer()

            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.panel))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Colors.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                displayedMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
            } label: {
                Text("Today")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Colors.textDim)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.panel))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Colors.border, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.Colors.textDim)
                    .frame(width: 24, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.panel))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Colors.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func shiftMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) {
            displayedMonth = calendar.dateInterval(of: .month, for: next)?.start ?? next
        }
    }

    // MARK: - Day cell

    private func dayCell(_ slot: DaySlot) -> some View {
        let isToday = slot.date.map { calendar.isDateInToday($0) } ?? false
        let visible = Array(slot.records.prefix(3))
        return VStack(alignment: .leading, spacing: 3) {
            if let date = slot.date {
                Text("\(calendar.component(.day, from: date))")
                    .font(.system(size: 10.5, weight: isToday ? .bold : .regular, design: .monospaced))
                    .foregroundStyle(isToday ? Theme.Colors.accentText : Theme.Colors.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                ForEach(visible) { record in
                    recordChip(record)
                }
                if slot.records.count > visible.count {
                    Text("+\(slot.records.count - visible.count) more")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Colors.tertiaryText)
                        .padding(.leading, 2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(4)
        .frame(minHeight: 78, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(slot.date == nil ? Color.clear : (isToday ? Theme.Colors.accent.opacity(0.06) : Theme.Colors.bg1.opacity(0.55)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(isToday ? Theme.Colors.accent.opacity(0.5) : (slot.date == nil ? Color.clear : Theme.Colors.borderSubtle), lineWidth: 1)
        )
    }

    /// Chip color: the record's first single-select value's option color, so
    /// e.g. session types tint their calendar entries.
    private func chipColor(_ record: CustomRecord) -> Color {
        for field in collection.sortedFields where field.kind == .singleSelect {
            if case .optionIds(let ids)? = record.values[field.id],
               let first = ids.first,
               let option = field.options.first(where: { $0.id == first }),
               let color = Color.fromHex(option.colorHex) {
                return color
            }
        }
        return Theme.Colors.accent
    }

    private func recordChip(_ record: CustomRecord) -> some View {
        let color = chipColor(record)
        return Button {
            onOpen(record)
        } label: {
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 4, height: 4)
                Text(record.displayTitle(in: tab))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.text)
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                onDelete(record)
            } label: {
                Label("Delete record", systemImage: "trash")
            }
        }
    }
}
