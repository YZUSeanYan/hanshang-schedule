/**
 * HTTP 客户端：统一 baseUrl / 超时 / JSON 处理 + JWT 自动附带 + 401 刷新重试。
 * 移植自 Flutter 版 core/network/api_client.dart 的 AuthInterceptor 语义：
 * - 认证免登录接口（login/register/refresh/forgot/reset）不附带 Authorization；
 * - 业务接口 401 → 用 refresh token 换新（单飞防并发重复刷新）→ 重放一次；
 * - 服务器明确拒绝 refresh（400/401/403）→ 清空本地凭据；
 * - 网络异常 → 保留凭据，已登录用户继续使用离线课表。
 */
import { http } from '@kit.NetworkKit';
import { AppConfig } from '../common/AppConfig';
import { TokenStore } from '../storage/TokenStore';

/** 服务端统一错误：httpStatus=0 表示网络不通/超时（继承 Error 以满足 arkts-limited-throw） */
export class ApiError extends Error {
  readonly httpStatus: number;
  readonly code: number;

  constructor(httpStatus: number, code: number, message: string) {
    super(message);
    this.name = 'ApiError';
    this.httpStatus = httpStatus;
    this.code = code;
  }

  static network(message: string): ApiError {
    return new ApiError(0, -1, message);
  }

  /** 服务器明确拒绝凭据（应注销本地登录态） */
  isDefinitiveAuthFailure(): boolean {
    return this.httpStatus === 400 || this.httpStatus === 401 || this.httpStatus === 403;
  }

  /** 暂时性故障（可保留本地凭据走离线会话） */
  isTransient(): boolean {
    return this.httpStatus === 0 || this.httpStatus === 408
      || this.httpStatus === 429 || this.httpStatus >= 500;
  }
}

interface HttpTextResp {
  status: number;
  bodyText: string;
}

function isAuthFree(path: string): boolean {
  return path.startsWith('/api/auth/login')
    || path.startsWith('/api/auth/register')
    || path.startsWith('/api/auth/refresh')
    || path.startsWith('/api/auth/forgot-password')
    || path.startsWith('/api/auth/reset-password');
}

export class ApiClient {
  private static refreshInFlight: Promise<boolean> | null = null;

  /** 统一入口：成功返回服务端 data 字段（Object），失败抛 ApiError */
  static async request(method: http.RequestMethod, path: string,
    body: Record<string, Object> | null): Promise<Object> {
    const first = await ApiClient.attempt(method, path, body);
    if (first.status === 401 && !isAuthFree(path)) {
      const refreshed = await ApiClient.refreshOnce();
      if (refreshed) {
        const second = await ApiClient.attempt(method, path, body);
        return ApiClient.parseSuccess(second);
      }
    }
    return ApiClient.parseSuccess(first);
  }

  static async get(path: string): Promise<Object> {
    return ApiClient.request(http.RequestMethod.GET, path, null);
  }

  static async post(path: string, body: Record<string, Object>): Promise<Object> {
    return ApiClient.request(http.RequestMethod.POST, path, body);
  }

  static async delete(path: string): Promise<Object> {
    return ApiClient.request(http.RequestMethod.DELETE, path, null);
  }

  private static async attempt(method: http.RequestMethod, path: string,
    body: Record<string, Object> | null): Promise<HttpTextResp> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (!isAuthFree(path)) {
      const token = await TokenStore.readAccessToken();
      if (token !== null) {
        headers['Authorization'] = `Bearer ${token}`;
      }
    }
    const bodyText = body === null ? null : JSON.stringify(body);
    return ApiClient.raw(method, path, headers, bodyText);
  }

  private static async raw(method: http.RequestMethod, path: string,
    headers: Record<string, string>, bodyText: string | null): Promise<HttpTextResp> {
    const client = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: method,
        header: headers,
        expectDataType: http.HttpDataType.STRING,
        connectTimeout: 10000,
        readTimeout: 15000
      };
      if (bodyText !== null) {
        options.extraData = bodyText;
      }
      const resp = await client.request(AppConfig.API_BASE_URL + path, options);
      const result = resp.result;
      const text = typeof result === 'string' ? result : '';
      return { status: resp.responseCode, bodyText: text };
    } catch (e) {
      throw ApiError.network('无法连接服务器，请检查网络');
    } finally {
      client.destroy();
    }
  }

  /** 2xx → 取 data 字段；非 2xx → 抛带服务端 message 的 ApiError */
  private static parseSuccess(resp: HttpTextResp): Object {
    if (resp.status >= 200 && resp.status < 300) {
      const parsed = ApiClient.tryParseJson(resp.bodyText);
      if (parsed !== null) {
        const data = (parsed as Record<string, Object>)['data'];
        if (data !== undefined) {
          return data;
        }
      }
      const empty: Record<string, Object> = {};
      return empty;
    }
    let message = `请求失败（${resp.status}）`;
    let serverCode = -1;
    const parsed = ApiClient.tryParseJson(resp.bodyText);
    if (parsed !== null) {
      const map = parsed as Record<string, Object>;
      const m = map['message'];
      if (typeof m === 'string' && m.length > 0) {
        message = m;
      }
      const c = map['code'];
      if (typeof c === 'number') {
        serverCode = c;
      }
    }
    throw new ApiError(resp.status, serverCode, message);
  }

  private static tryParseJson(text: string): Object | null {
    if (text.length === 0) {
      return null;
    }
    try {
      return JSON.parse(text) as Object;
    } catch (e) {
      return null;
    }
  }

  /** 单飞刷新：并发 401 只触发一次 refresh（对应 Flutter QueuedInterceptor） */
  private static refreshOnce(): Promise<boolean> {
    if (ApiClient.refreshInFlight !== null) {
      return ApiClient.refreshInFlight;
    }
    const task = ApiClient.doRefresh();
    ApiClient.refreshInFlight = task;
    task.then(() => {
      ApiClient.refreshInFlight = null;
    }, () => {
      ApiClient.refreshInFlight = null;
    });
    return task;
  }

  private static async doRefresh(): Promise<boolean> {
    const refreshToken = await TokenStore.readRefreshToken();
    if (refreshToken === null) {
      return false;
    }
    let resp: HttpTextResp;
    try {
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      const body: Record<string, Object> = { 'refresh_token': refreshToken };
      resp = await ApiClient.raw(http.RequestMethod.POST, '/api/auth/refresh',
        headers, JSON.stringify(body));
    } catch (e) {
      // 断网/服务器暂不可用：保留本地凭证走离线
      return false;
    }
    if (resp.status >= 200 && resp.status < 300) {
      const parsed = ApiClient.tryParseJson(resp.bodyText);
      const data = parsed !== null ? (parsed as Record<string, Object>)['data'] : undefined;
      if (data !== undefined) {
        const tokenMap = data as Record<string, Object>;
        const access = tokenMap['access_token'];
        const refresh = tokenMap['refresh_token'];
        if (typeof access === 'string' && typeof refresh === 'string') {
          await TokenStore.saveTokens(access, refresh);
          return true;
        }
      }
      return false;
    }
    if (resp.status === 400 || resp.status === 401 || resp.status === 403) {
      // 服务器明确拒绝 refresh token：注销
      await TokenStore.clear();
    }
    return false;
  }
}

/** 从 ApiError 提取用户可读文案（对应 Flutter apiErrorMessage） */
export function apiErrorMessage(error: Object, fallback: string = '网络异常，请稍后重试'): string {
  if (error instanceof ApiError) {
    return (error as ApiError).message;
  }
  return fallback;
}
