"""Provider-neutral data contract for native notification routing."""

NOTIFICATION_PAYLOAD_VERSION = "1"
NOTIFICATION_DESTINATION = "notifications"
NOTIFICATION_DEEPLINK = "hanshang://notifications"


def build_notification_payload(notification_id: int) -> dict[str, str]:
    """Return the versioned, string-only payload shared by native providers."""
    return {
        "version": NOTIFICATION_PAYLOAD_VERSION,
        "type": "account_notification",
        "destination": NOTIFICATION_DESTINATION,
        "deeplink": NOTIFICATION_DEEPLINK,
        "notification_id": str(notification_id),
    }
