"""Validate uploaded timetable files and reduce spreadsheets to bounded text.

The parser never persists uploads. Images are passed through only after magic
byte validation; spreadsheets are opened read-only and converted to a compact
layout-preserving text representation before the MiMo request is made.
"""
from __future__ import annotations

import csv
import datetime as dt
import io
import zipfile
from dataclasses import dataclass
from pathlib import PurePath
from typing import Literal

import openpyxl
import xlrd

from app.services.llm_schedule_import import strip_identity_info

MAX_UPLOAD_BYTES = 8 * 1024 * 1024
MAX_IMAGE_BYTES = 8 * 1024 * 1024
MAX_SPREADSHEET_BYTES = 5 * 1024 * 1024
MAX_ARCHIVE_ENTRIES = 500
MAX_ARCHIVE_UNCOMPRESSED_BYTES = 40 * 1024 * 1024
MAX_SHEETS = 12
MAX_ROWS_PER_SHEET = 300
MAX_COLUMNS_PER_SHEET = 60
MAX_NONEMPTY_CELLS = 6000
MAX_TABLE_CHARS = 100_000

_IMAGE_SIGNATURES = (
    (b"\x89PNG\r\n\x1a\n", "image/png"),
    (b"\xff\xd8\xff", "image/jpeg"),
)
_XLS_SIGNATURE = b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1"


class FileScheduleImportError(Exception):
    def __init__(self, status_code: int, code: int, message: str):
        super().__init__(message)
        self.status_code = status_code
        self.code = code
        self.message = message


@dataclass(frozen=True)
class PreparedScheduleFile:
    kind: Literal["image", "spreadsheet"]
    mime_type: str = ""
    image: bytes = b""
    table_text: str = ""


def prepare_schedule_file(filename: str, data: bytes) -> PreparedScheduleFile:
    if not data:
        raise FileScheduleImportError(400, 40041, "上传的文件为空")
    if len(data) > MAX_UPLOAD_BYTES:
        raise FileScheduleImportError(413, 41341, "文件过大，请上传不超过 8 MB 的课表文件")

    mime = _image_mime(data)
    if mime:
        if len(data) > MAX_IMAGE_BYTES:
            raise FileScheduleImportError(413, 41341, "课表截图不能超过 8 MB")
        return PreparedScheduleFile(kind="image", mime_type=mime, image=data)

    suffix = PurePath(filename or "").suffix.lower()
    if _looks_like_xlsx(data):
        if len(data) > MAX_SPREADSHEET_BYTES:
            raise FileScheduleImportError(413, 41342, "Excel 文件不能超过 5 MB")
        return PreparedScheduleFile(
            kind="spreadsheet", table_text=_extract_xlsx(data)
        )
    if data.startswith(_XLS_SIGNATURE):
        if len(data) > MAX_SPREADSHEET_BYTES:
            raise FileScheduleImportError(413, 41342, "Excel 文件不能超过 5 MB")
        return PreparedScheduleFile(
            kind="spreadsheet", table_text=_extract_xls(data)
        )
    if suffix == ".csv":
        if len(data) > MAX_SPREADSHEET_BYTES:
            raise FileScheduleImportError(413, 41342, "CSV 文件不能超过 5 MB")
        return PreparedScheduleFile(
            kind="spreadsheet", table_text=_extract_csv(data)
        )
    raise FileScheduleImportError(
        415,
        41541,
        "仅支持 PNG、JPG、WebP 课表截图及 XLSX、XLS、CSV 表格",
    )


def _image_mime(data: bytes) -> str | None:
    for signature, mime in _IMAGE_SIGNATURES:
        if data.startswith(signature):
            return mime
    if len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


def _looks_like_xlsx(data: bytes) -> bool:
    if not data.startswith(b"PK"):
        return False
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            names = set(archive.namelist())
            return "[Content_Types].xml" in names and "xl/workbook.xml" in names
    except (zipfile.BadZipFile, OSError):
        return False


def _validate_xlsx_archive(data: bytes) -> None:
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            infos = archive.infolist()
            if len(infos) > MAX_ARCHIVE_ENTRIES:
                raise FileScheduleImportError(413, 41343, "Excel 文件结构过于复杂")
            if sum(item.file_size for item in infos) > MAX_ARCHIVE_UNCOMPRESSED_BYTES:
                raise FileScheduleImportError(413, 41343, "Excel 文件解压后过大")
            if any(".." in PurePath(item.filename).parts for item in infos):
                raise FileScheduleImportError(400, 40042, "Excel 文件结构无效")
    except zipfile.BadZipFile as exc:
        raise FileScheduleImportError(400, 40042, "Excel 文件已损坏") from exc


def _extract_xlsx(data: bytes) -> str:
    _validate_xlsx_archive(data)
    try:
        workbook = openpyxl.load_workbook(
            io.BytesIO(data), read_only=True, data_only=True
        )
    except Exception as exc:
        raise FileScheduleImportError(400, 40042, "Excel 文件无法读取") from exc
    try:
        sheets: list[tuple[str, list[list[object]]]] = []
        for sheet in workbook.worksheets[:MAX_SHEETS]:
            rows = [
                list(row[:MAX_COLUMNS_PER_SHEET])
                for row in sheet.iter_rows(
                    min_row=1,
                    max_row=min(sheet.max_row or 1, MAX_ROWS_PER_SHEET),
                    values_only=True,
                )
            ]
            sheets.append((sheet.title, rows))
        return _render_sheets(sheets)
    finally:
        workbook.close()


def _extract_xls(data: bytes) -> str:
    try:
        workbook = xlrd.open_workbook(file_contents=data, on_demand=True)
    except Exception as exc:
        raise FileScheduleImportError(400, 40042, "XLS 文件无法读取") from exc
    try:
        sheets: list[tuple[str, list[list[object]]]] = []
        for name in workbook.sheet_names()[:MAX_SHEETS]:
            sheet = workbook.sheet_by_name(name)
            rows = [
                sheet.row_values(row, 0, min(sheet.ncols, MAX_COLUMNS_PER_SHEET))
                for row in range(min(sheet.nrows, MAX_ROWS_PER_SHEET))
            ]
            sheets.append((name, rows))
        return _render_sheets(sheets)
    finally:
        workbook.release_resources()


def _extract_csv(data: bytes) -> str:
    text = None
    for encoding in ("utf-8-sig", "gb18030"):
        try:
            text = data.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    if text is None or "\x00" in text:
        raise FileScheduleImportError(400, 40043, "CSV 编码无法识别")
    try:
        rows = []
        for index, row in enumerate(csv.reader(io.StringIO(text))):
            if index >= MAX_ROWS_PER_SHEET:
                break
            rows.append(row[:MAX_COLUMNS_PER_SHEET])
    except csv.Error as exc:
        raise FileScheduleImportError(400, 40043, "CSV 文件无法读取") from exc
    return _render_sheets([("CSV", rows)])


def _render_sheets(sheets: list[tuple[str, list[list[object]]]]) -> str:
    output: list[str] = []
    nonempty = 0
    length = 0
    for name, rows in sheets:
        header = f"工作表：{strip_identity_info(str(name))}"
        output.append(header)
        length += len(header) + 1
        for row_number, row in enumerate(rows, 1):
            rendered: list[str] = []
            last_nonempty = -1
            for column, value in enumerate(row):
                cell = _cell_text(value)
                rendered.append(cell)
                if cell:
                    last_nonempty = column
                    nonempty += 1
                    if nonempty > MAX_NONEMPTY_CELLS:
                        raise FileScheduleImportError(413, 41343, "表格有效单元格过多")
            if last_nonempty < 0:
                continue
            line = f"{row_number}\t" + "\t".join(rendered[: last_nonempty + 1])
            length += len(line) + 1
            if length > MAX_TABLE_CHARS:
                raise FileScheduleImportError(413, 41343, "表格内容过多，请只保留课表区域")
            output.append(line)
    if nonempty < 3:
        raise FileScheduleImportError(422, 42241, "表格中没有足够的课表内容")
    # A label and its value commonly occupy adjacent cells ("姓名" | "张三").
    # Run the scrubber once more over the rendered table so that cross-cell
    # identity pairs are removed before the text leaves this server.
    return strip_identity_info("\n".join(output))


def _cell_text(value: object) -> str:
    if value is None:
        return ""
    if isinstance(value, (dt.datetime, dt.date, dt.time)):
        text = value.isoformat()
    elif isinstance(value, float) and value.is_integer():
        text = str(int(value))
    else:
        text = str(value)
    text = " ".join(text.replace("\t", " ").replace("\r", " ").splitlines()).strip()
    return strip_identity_info(text[:500])
