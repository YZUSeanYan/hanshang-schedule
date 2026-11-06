/**
 * 分享仓库：生成/预览/领取分享口令。
 * 移植自 Flutter 版 features/share/data/share_repository.dart。
 */
import { ApiClient } from '../../network/ApiClient';
import { ShareCodeInfo, SharePreview, SharePreviewCourse } from './ShareTypes';

export class ShareRepository {
  /** 为当前学期生成分享口令(7 天有效) */
  static async create(semesterUuid: string): Promise<ShareCodeInfo> {
    const data = await ApiClient.post('/api/share/create', {
      'semester_uuid': semesterUuid
    }) as Record<string, Object>;
    return {
      code: data['code'] as string,
      expiresAt: data['expires_at'] as string
    } as ShareCodeInfo;
  }

  /** 预览口令对应的课表快照(不写本地库) */
  static async preview(code: string): Promise<SharePreview> {
    const data = await ApiClient.get(`/api/share/${encodeURIComponent(code)}`) as Record<string, Object>;
    const payload = data['payload'] as Record<string, Object>;
    const semester = payload['semester'] as Record<string, Object>;
    const courses = (payload['courses'] as Object[] ?? []);
    const preview: SharePreview = {
      semesterName: (semester['name'] as string) ?? '',
      courseCount: courses.length,
      expiresAt: (data['expires_at'] as string) ?? '',
      courses: courses.map((c) => {
        const course = c as Record<string, Object>;
        const spc: SharePreviewCourse = {
          name: (course['name'] as string) ?? '',
          teacher: (course['teacher'] as string) ?? '',
          slotCount: ((course['slots'] as Object[]) ?? []).length
        };
        return spc;
      })
    };
    return preview;
  }

  /** 领取口令课表为独立副本(返回课程数)。409=同名学期需确认覆盖 */
  static async claim(code: string, replaceExisting: boolean): Promise<number> {
    const data = await ApiClient.post(`/api/share/${encodeURIComponent(code)}/claim`, {
      'replace_existing': replaceExisting
    }) as Record<string, Object>;
    return (data['course_count'] as number) ?? 0;
  }
}
