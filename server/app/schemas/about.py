from pydantic import BaseModel, Field, field_validator


class AdminAboutUpdateIn(BaseModel):
    display_name: str = Field(min_length=1, max_length=80)
    icp_beian: str = Field(default="", max_length=64, description="工信部备案号")
    intro: str = Field(default="", max_length=5000)
    website_url: str = Field(default="", max_length=500)

    @field_validator("display_name", "intro", "website_url", "icp_beian")
    @classmethod
    def strip_text(cls, value: str) -> str:
        return value.strip()

    @field_validator("website_url")
    @classmethod
    def validate_website(cls, value: str) -> str:
        if value and not value.lower().startswith(("https://", "http://")):
            raise ValueError("官网链接必须以 http:// 或 https:// 开头")
        return value
