import SwiftUI
import WidgetKit

private let appGroupId = "group.cn.yzu.schedule.yzuSchedule"
private let widgetKind = "TodayCoursesWidget"

private struct CourseItem: Codable {
  let time: String
  let name: String
  let loc: String
}

private struct TodayCoursesEntry: TimelineEntry {
  let date: Date
  let title: String
  let courses: [CourseItem]
}

private struct TodayCoursesProvider: TimelineProvider {
  func placeholder(in context: Context) -> TodayCoursesEntry {
    TodayCoursesEntry(
      date: Date(),
      title: "今天 · 第1周",
      courses: [CourseItem(time: "08:00", name: "今日课程", loc: "教室")]
    )
  }

  func getSnapshot(in context: Context, completion: @escaping (TodayCoursesEntry) -> Void) {
    completion(loadEntry())
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<TodayCoursesEntry>) -> Void) {
    let entry = loadEntry()
    // Dart 侧在课程变化时主动 reload；这里每天定期兜底刷新日期与空态。
    let nextRefresh = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
    completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
  }

  private func loadEntry() -> TodayCoursesEntry {
    let defaults = UserDefaults(suiteName: appGroupId)
    let title = defaults?.string(forKey: "today_title") ?? "邗上课表"
    let raw = defaults?.string(forKey: "today_courses_json") ?? "[]"
    let courses = (try? JSONDecoder().decode([CourseItem].self, from: Data(raw.utf8))) ?? []
    return TodayCoursesEntry(date: Date(), title: title, courses: courses)
  }
}

private struct TodayCoursesView: View {
  @Environment(\.widgetFamily) private var family
  let entry: TodayCoursesEntry

  private var visibleCourses: [CourseItem] {
    Array(entry.courses.prefix(family == .systemSmall ? 3 : 6))
  }

  var body: some View {
    ZStack {
      Color(red: 0.94, green: 0.98, blue: 0.95)
      VStack(alignment: .leading, spacing: 5) {
        Text(entry.title)
          .font(.headline)
          .foregroundColor(Color(red: 0.02, green: 0.42, blue: 0.25))
          .lineLimit(1)

        if visibleCourses.isEmpty {
          Spacer()
          Text("今天没有课")
            .font(.subheadline)
            .foregroundColor(.secondary)
          Spacer()
        } else {
          ForEach(Array(visibleCourses.enumerated()), id: \.offset) { _, course in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(course.time)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
              VStack(alignment: .leading, spacing: 1) {
                Text(course.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                if !course.loc.isEmpty {
                  Text(course.loc).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                }
              }
            }
          }
          Spacer(minLength: 0)
        }
      }
      .padding()
    }
  }
}

@main
struct TodayCoursesWidget: Widget {
  let kind = widgetKind

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: TodayCoursesProvider()) { entry in
      TodayCoursesView(entry: entry)
    }
    .configurationDisplayName("今日课程")
    .description("查看今天的上课时间、课程与地点。")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
