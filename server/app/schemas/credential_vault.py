from pydantic import BaseModel, Field


class CredentialVaultIn(BaseModel):
    ciphertext: str = Field(min_length=24, max_length=16384, pattern=r"^[A-Za-z0-9+/=]+$")
    nonce: str = Field(min_length=16, max_length=64, pattern=r"^[A-Za-z0-9+/=]+$")
    student_id_hint: str = Field(default="", max_length=12, pattern=r"^[0-9A-Za-z*_-]*$")
    schema_version: int = Field(default=1, ge=1, le=10)
