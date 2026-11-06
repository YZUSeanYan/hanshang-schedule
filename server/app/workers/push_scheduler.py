"""Call the authenticated push dispatcher every five minutes."""
import json
import os
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def dispatch_once() -> bool:
    token = os.environ.get("ADMIN_TOKEN", "")
    if not token:
        return False
    request = Request(
        "http://api:8000/api/push/dispatch",
        data=b"{}",
        method="POST",
        headers={"Content-Type": "application/json", "X-Admin-Token": token},
    )
    try:
        with urlopen(request, timeout=30) as response:
            body = json.loads(response.read().decode("utf-8"))
            return response.status == 200 and body.get("code") == 0
    except (HTTPError, URLError, TimeoutError, json.JSONDecodeError):
        return False


def main() -> None:
    while True:
        dispatch_once()
        time.sleep(300)


if __name__ == "__main__":
    main()
