"""服务器代抓教务导入功能已于 2026-09-02 全面下线。

合规红线：服务器不接收、不存储任何学号、教务密码或课表页面。
端点不再解析请求体（学号/密码根本不会进入服务端处理流程），一律返回
410 Gone。导入改由用户设备本地完成（App 内 WebView 手动导入 / 粘贴解析），
凭据全程不离开用户设备。

webvpn_import.py / portal_import.py 服务代码保留但无任何入口可达；
若未来恢复该功能，必须先重新通过合规审查。
"""
from fastapi import APIRouter, HTTPException

router = APIRouter(prefix="/education-import", tags=["教务代抓"])

_GONE = {
    "code": 41031,
    "message": "服务器代抓导入已下线，请改用 App 内手动导入：凭据不离开你的设备",
}


@router.post("/webvpn", response_model=None)
async def import_from_webvpn() -> None:
    raise HTTPException(status_code=410, detail=_GONE)
