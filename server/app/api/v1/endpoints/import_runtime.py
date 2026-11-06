"""Public signed declarative import configuration. No account or school data."""
from pathlib import Path
from fastapi import APIRouter, HTTPException
from fastapi.responses import Response

router = APIRouter()
RUNTIME_FILE = Path('/data/import-runtime-v1.json')
MAX_BYTES = 196608

@router.get('/import-runtime')
def get_import_runtime():
    try:
        with RUNTIME_FILE.open('rb') as stream:
            payload = stream.read(MAX_BYTES + 1)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail='No runtime published')
    if len(payload) > MAX_BYTES:
        raise HTTPException(status_code=503, detail='Runtime unavailable')
    # Signature verification and build compatibility are enforced by the app.
    return Response(payload, media_type='application/json', headers={'Cache-Control': 'no-store'})
