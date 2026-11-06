/**
 * 课表模块的数据模型。
 * 移植自 Flutter 版 features/sync/data/schedule_repository.dart 的 CourseEntry/SlotDraft/CourseDraft。
 * 纯类型 + 纯逻辑(无 @ohos 依赖)。
 */

import { SemRow, CourseRow, SchedRow } from '../../model/SyncCodecs';

/** 一门课及其全部上课时间段(页面渲染用) */
export interface CourseEntry {
  course: CourseRow;
  slots: SchedRow[];
}

/** 课程编辑页提交的时间段草稿(无 id/updatedAt) */
export interface SlotDraft {
  dayOfWeek: number; // 1=周一 … 7=周日
  startSection: number; // 1-12
  endSection: number;
  weeksType: number; // 0=每周 1=单周 2=双周 3=自定义
  customWeeks: number[];
  location: string;
}

/** 批量导入使用的课程草稿 */
export interface CourseDraft {
  name: string;
  teacher: string;
  color: number; // ARGB int,-1 表示按课名哈希自动分配
  note: string;
  slots: SlotDraft[];
}

/** 学期(直接使用数据库行类型) */
export type Semester = SemRow;
