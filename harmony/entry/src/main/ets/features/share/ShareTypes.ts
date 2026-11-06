/**
 * 分享模块类型。
 * 移植自 Flutter 版 features/share/data/share_repository.dart。
 * 纯类型(无 @ohos 依赖)。
 */

/** 服务端生成的 7 天有效分享口令 */
export interface ShareCodeInfo {
  code: string;
  expiresAt: string; // ISO 时间字符串
}

/** 分享口令对应的课表快照预览 */
export interface SharePreview {
  semesterName: string;
  courseCount: number;
  expiresAt: string;
  courses: SharePreviewCourse[];
}

export interface SharePreviewCourse {
  name: string;
  teacher: string;
  slotCount: number;
}

/** 分享口令对应的完整快照 payload(领取用) */
export interface SharePayload {
  version: number;
  semester: {
    name: string;
    start_date: string;
    total_weeks: number;
  };
  courses: SharePayloadCourse[];
}

export interface SharePayloadCourse {
  name: string;
  teacher: string;
  color: number;
  slots: SharePayloadSlot[];
}

export interface SharePayloadSlot {
  day_of_week: number;
  start_section: number;
  end_section: number;
  weeks_type: number;
  custom_weeks: string;
  location: string;
}
