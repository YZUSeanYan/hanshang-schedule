"""教务凭据同步功能已于 2026-09-02 全面下线。

合规红线：服务器不接收、不存储任何教务密码、课表页面或与之相关的个人信息。
所有端点一律返回 410 Gone，请求体不再被解析；数据库 credential_vaults 表
已清空。管理后台仅保留对历史残留行的删除能力（见 admin_console.py）。
"""
from fastapi import APIRouter, HTTPException

router = APIRouter(prefix="/credential-vault", tags=["credential-vault"])

_GONE = {
    "code": 41030,
    "message": "教务凭据同步功能已下线：服务器不接收、不存储任何教务凭据",
}


@router.get("")
def get_vault() -> None:
    raise HTTPException(status_code=410, detail=_GONE)


@router.put("")
def put_vault() -> None:
    raise HTTPException(status_code=410, detail=_GONE)


@router.post("/verified")
def mark_round_trip_verified() -> None:
    raise HTTPException(status_code=410, detail=_GONE)


@router.delete("")
def delete_vault() -> None:
    raise HTTPException(status_code=410, detail=_GONE)
