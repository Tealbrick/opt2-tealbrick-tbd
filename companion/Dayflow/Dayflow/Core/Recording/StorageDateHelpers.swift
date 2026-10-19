//
//  StorageManager.swift
//  Dayflow
//

import Foundation
import GRDB
import TBDModels

extension DateFormatter {
  static let yyyyMMdd: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = Calendar.current.timeZone
    return formatter
  }()
}

extension Date {
  /// The start and end of the Companion day (4 AM to 4 AM) that this date falls in, in `calendar`.
  private func fourAMDayRange(calendar: Calendar) -> (start: Date, end: Date) {
    guard let fourAMToday = calendar.date(bySettingHour: 4, minute: 0, second: 0, of: self) else {
      print("Error: Could not calculate 4 AM for date \(self). Falling back to standard day.")
      let start = calendar.startOfDay(for: self)
      return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
    }
    let start = self < fourAMToday ? calendar.date(byAdding: .day, value: -1, to: fourAMToday)! : fourAMToday
    return (start, calendar.date(byAdding: .day, value: 1, to: start)!)
  }

  /// Calculates the "day" based on a 4 AM start time.
  /// Returns the date string (YYYY-MM-DD) and the Date objects for the start and end of that day.
  func getDayInfoFor4AMBoundary() -> (dayString: String, startOfDay: Date, endOfDay: Date) {
    let range = fourAMDayRange(calendar: Calendar.current)
    return (DateFormatter.yyyyMMdd.string(from: range.start), range.start, range.end)
  }

  /// The same Companion day in a given calendar (Flow and its tests inject the calendar).
  func getDayInfoFor4AMBoundary(calendar: Calendar) -> (dayString: String, startOfDay: Date, endOfDay: Date) {
    let range = fourAMDayRange(calendar: calendar)
    return (TBDFlowDay.string(from: range.start, calendar: calendar), range.start, range.end)
  }
}
