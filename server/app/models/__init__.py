"""数据模型包：导入此包即注册全部模型到 Base.metadata。"""
from app.models.app_version import AppVersion
from app.models.admin import AdminAuditLog, AdminSession, UserRestriction
from app.models.email_code import EmailCode
from app.models.device_pair import DevicePairCode
from app.models.sync_data import SyncCourse, SyncSchedule, SyncSemester
from app.models.user import User
from app.models.about_content import AboutContent
from app.models.credential_vault import CredentialVault
from app.models.token_session import RefreshTokenSession, UserTokenState
from app.models.share_code import ShareCode
from app.models.push_subscription import PushDelivery, PushSubscription
from app.models.notification import UserNotification, UserPushDevice
from app.models.couple_schedule import CoupleConnection, CoupleMembership
from app.models.release_target import AppFeatureGrant, AppVersionTarget
from app.models.onboarding_reminder import OnboardingReminder
from app.models.personal_event import SyncEvent
from app.models.import_event import ImportEvent
from app.models.reminder_status import ReminderStatus
from app.models.client_version import ClientVersion

__all__ = [
    "User",
    "EmailCode",
    "DevicePairCode",
    "AppVersion",
    "SyncSemester",
    "SyncCourse",
    "SyncSchedule",
    "AdminSession",
    "AdminAuditLog",
    "UserRestriction",
    "AboutContent",
    "CredentialVault",
    "RefreshTokenSession",
    "UserTokenState",
    "ShareCode",
    "PushSubscription",
    "PushDelivery",
    "UserNotification",
    "UserPushDevice",
    "CoupleConnection",
    "CoupleMembership",
    "AppFeatureGrant",
    "AppVersionTarget",
    "OnboardingReminder",
    "SyncEvent",
    "ImportEvent",
    "ReminderStatus",
]
from app.models.daily_activity import DailyActivity  # noqa: F401
