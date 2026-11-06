"""Authenticated, rate-limited LLM fallback for unrecognized timetable pages."""
import asyncio
import datetime as dt
import time

from fastapi import APIRouter, Depends, File, HTTPException, Request, UploadFile
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.config import get_settings
from app.core.ratelimit import RateLimiter
from app.db.session import get_db
from app.models.sync_data import SyncSemester
from app.models.user import User
from app.schemas.llm_schedule_import import LlmImportIn, LlmImportOut
from app.services.academic_schedule_parser import (
    AcademicScheduleParseError,
    courses_to_response,
)
from app.services.import_events import record_import_event
from app.services.llm_schedule_import import (
    LlmScheduleImportError,
    LlmScheduleImportGateway,
    MimoScheduleGateway,
    UnavailableLlmScheduleGateway,
    strip_identity_info,
)
from app.services.file_schedule_import import (
    FileScheduleImportError,
    MAX_UPLOAD_BYTES,
    prepare_schedule_file,
)

router = APIRouter(prefix="/education-import", tags=["教务 LLM 解析"])

# Cheaper than a Playwright import, so the budget is wider: ten parses per
# user per day, six hundred per origin IP. Campus and carrier networks often
# share one public address, so the IP ceiling must not become a global quota
# for dozens of authenticated students. In-memory like the existing limiters;
# multi-worker deployment must replace this with a shared limiter first.
_user_daily_limiter = RateLimiter(10, 24 * 60 * 60)
_ip_daily_limiter = RateLimiter(600, 24 * 60 * 60)
_settings = get_settings()
_gateway: LlmScheduleImportGateway = (
    MimoScheduleGateway(
        base_url=_settings.llm_import_base_url,
        api_key=_settings.llm_import_api_key,
        model=_settings.llm_import_model,
        timeout_seconds=_settings.llm_import_timeout_seconds,
    )
    if _settings.llm_import_enabled and _settings.llm_import_api_key
    else UnavailableLlmScheduleGateway()
)


def _rate_limit(request: Request, user: User, db: Session, entry: str) -> None:
    client_ip = request.client.host if request.client else "unknown"
    if not _user_daily_limiter.allow(f"llm-import:user:{user.id}"):
        _emit(db, user.id, entry, "fail", "42933", "")
        raise HTTPException(status_code=429, detail={"code": 42933, "message": "今日智能解析次数已达上限"})
    if not _ip_daily_limiter.allow(f"llm-import:ip:{client_ip}"):
        _emit(db, user.id, entry, "fail", "42934", "")
        raise HTTPException(status_code=429, detail={"code": 42934, "message": "当前网络的智能解析请求过于频繁"})


# ---- 埋点辅助：只记录文件类型/大小档/耗时档等元数据，不记录任何内容 ----

def _size_bucket(size: int) -> str:
    if size < 100 * 1024:
        return "<100k"
    if size < 1024 * 1024:
        return "100k_1m"
    if size < 5 * 1024 * 1024:
        return "1m_5m"
    return ">5m"


def _ms_bucket(started: float) -> str:
    ms = (time.monotonic() - started) * 1000
    if ms < 1000:
        return "<1s"
    if ms < 5000:
        return "1_5s"
    if ms < 15000:
        return "5_15s"
    if ms < 50000:
        return "15_50s"
    return ">50s"


def _entry_of(content_type: str, filename: str) -> str:
    """按 content_type/扩展名区分截图与表格入口；判不出来返回空串（不记录）。"""
    ct = (content_type or "").lower()
    ext = filename.rsplit(".", 1)[-1].lower() if "." in (filename or "") else ""
    if ct.startswith("image/") or ext in {"png", "jpg", "jpeg", "webp", "bmp", "gif", "heic"}:
        return "screenshot"
    if any(k in ct for k in ("sheet", "excel", "csv", "ms-excel")) or ext in {"xlsx", "xls", "csv"}:
        return "excel"
    return ""


def _emit(db: Session, user_id: int, entry: str, outcome: str, error_code: str, detail: str) -> None:
    if entry:
        record_import_event(
            db, user_id=user_id, entry=entry, stage="parse", outcome=outcome,
            error_code=error_code, detail=detail, source="server",
        )


@router.post("/llm-parse", response_model=None)
async def import_via_llm(
    payload: LlmImportIn,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Parse one uploaded timetable page the client's rule parsers rejected."""
    started = time.monotonic()
    _rate_limit(request, user, db, "school")
    # 合规红线（2026-09-02）：姓名/学号在服务端边界即被抹除——原始身份值
    # 不进入解析流程、不送大模型、不写数据库与日志；客户端上传前同样脱敏。
    html = strip_identity_info(payload.html)
    captured = [strip_identity_info(body) for body in payload.captured]
    try:
        # Hard wall-clock cap below the Nginx 60 s proxy timeout, same contract
        # as the WebVPN import: a stall surfaces as structured 504, not a bare
        # `504 Gateway Time-out`.  Measured latency with reasoning disabled:
        # mimo-v2.5 was ~34 s, mimo-v2.6-flash is ~4 s, so the default 50 s
        # deadline now has very wide headroom.
        result = await asyncio.wait_for(
            _gateway.import_schedule(html=html, captured=captured),
            timeout=_settings.llm_import_deadline_seconds,
        )
        _emit(db, user.id, "school", "success", "", f"ms={_ms_bucket(started)}")
        return {
            "code": 0,
            "message": "ok",
            "data": LlmImportOut(
                courses=courses_to_response(result.courses),
                source=result.source,
            ).model_dump(),
        }
    except asyncio.TimeoutError:
        _emit(db, user.id, "school", "fail", "50434", f"ms={_ms_bucket(started)}")
        raise HTTPException(
            status_code=504,
            detail={"code": 50434, "message": "智能解析处理超时，请稍后重试"},
        ) from None
    except LlmScheduleImportError as exc:
        _emit(db, user.id, "school", "fail", str(exc.code), f"ms={_ms_bucket(started)}")
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from None
    except AcademicScheduleParseError as exc:
        # reason 是固定枚举（不含用户内容），记进 detail 便于统计失败成因。
        _emit(
            db,
            user.id,
            "school",
            "fail",
            "50231",
            f"ms={_ms_bucket(started)},reason={getattr(exc, 'reason', 'unknown')}",
        )
        raise HTTPException(
            status_code=502,
            detail={
                "code": 50231,
                "message": getattr(exc, "user_message", None) or "课表内容暂不支持解析",
            },
        ) from None


@router.post("/file-parse", response_model=None)
async def import_file_via_llm(
    request: Request,
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> dict:
    """Parse a timetable screenshot or spreadsheet without persisting it."""
    started = time.monotonic()
    entry = _entry_of(file.content_type or "", file.filename or "")
    _rate_limit(request, user, db, entry)
    raw = await file.read(MAX_UPLOAD_BYTES + 1)
    await file.close()
    # detail 必须在**每个**埋点时刻现算：原先在读完文件后立即取 ms 桶，
    # 导致 file-parse 的耗时永远是 <1s（实测截图解析要 1-4 秒），这个指标一直
    # 是废的。用闭包让每个 emit 点拿到自己那一刻的真实耗时。
    def _detail() -> str:
        return f"size={_size_bucket(len(raw))},ms={_ms_bucket(started)}"
    try:
        prepared = prepare_schedule_file(file.filename or "", raw)
        entry = "screenshot" if prepared.kind == "image" else "excel"
        if prepared.kind == "image":
            task = _gateway.import_image_schedule(
                image=prepared.image, mime_type=prepared.mime_type
            )
        else:
            # 分小班网格课表要把日期换算成学期周次、按上传者姓名筛小班，
            # 因此带上当前学期开学日与用户名；规则未命中时大模型分支不用它们。
            semester = (
                db.query(SyncSemester)
                .filter(SyncSemester.user_id == user.id, SyncSemester.is_current.is_(True))
                .order_by(SyncSemester.synced_at.desc())
                .first()
            )
            semester_start: dt.date | None = None
            if semester and semester.start_date:
                try:
                    semester_start = dt.date.fromisoformat(semester.start_date[:10])
                except ValueError:
                    semester_start = None
            task = _gateway.import_spreadsheet_schedule(
                table_text=prepared.table_text,
                username=user.username or "",
                semester_start=semester_start,
            )
        result = await asyncio.wait_for(
            task, timeout=_settings.llm_import_deadline_seconds
        )
        _emit(db, user.id, entry, "success", "", _detail())
        return {
            "code": 0,
            "message": "ok",
            "data": LlmImportOut(
                courses=courses_to_response(result.courses),
                source=result.source,
            ).model_dump(),
        }
    except FileScheduleImportError as exc:
        _emit(db, user.id, entry, "fail", str(exc.code), _detail())
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from None
    except asyncio.TimeoutError:
        _emit(db, user.id, entry, "fail", "50434", _detail())
        raise HTTPException(
            status_code=504,
            detail={"code": 50434, "message": "智能解析处理超时，请稍后重试"},
        ) from None
    except LlmScheduleImportError as exc:
        _emit(db, user.id, entry, "fail", str(exc.code), _detail())
        raise HTTPException(
            status_code=exc.status_code,
            detail={"code": exc.code, "message": exc.message},
        ) from None
    except AcademicScheduleParseError as exc:
        # reason 是固定枚举（不含用户内容），记进 detail 便于统计失败成因。
        _emit(
            db,
            user.id,
            entry,
            "fail",
            "42245",
            f"{_detail()},reason={getattr(exc, 'reason', 'unknown')}",
        )
        raise HTTPException(
            status_code=422,
            detail={
                "code": 42245,
                "message": getattr(exc, "user_message", None)
                or "没有识别到课表，请上传包含星期、节次和课程信息的完整截图或表格",
            },
        ) from None
