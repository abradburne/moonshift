from typing import Literal
from pydantic import BaseModel, Field, model_validator


class Project(BaseModel):
    """A cover: the reference song, its words, and the new sound.

    Unknown keys from older saved covers are ignored on load.
    """
    id: str = ""
    title: str = Field(default="Untitled cover", max_length=160)
    style: str = Field(default="", max_length=6000)
    lyrics: str = Field(default="", max_length=18000)
    abc: str = Field(default="", max_length=30000)
    voice: str = "ember"
    vocal_prompt: str = Field(default="", max_length=2000)
    language: str = "English"
    cot: Literal["full", "melody", "off"] = "full"
    seed: int = Field(default=831001, ge=0, lt=2**53)
    cfg_scale: float = Field(default=1.0, ge=0, le=5)
    temperature: float = Field(default=1.0, ge=0, le=2)
    max_tokens: int = Field(default=9000, ge=32, le=16000)
    ode_steps: int = Field(default=32, ge=4, le=64)
    takes: int = Field(default=1, ge=1, le=8)
    engine: Literal["auto", "metal-q8", "metal-q4"] | None = None
    nar_chunk_frames: Literal[0, 512, 1024, 2048, 4096] | None = None
    cover_source: str = ""
    cover_name: str = ""
    cover_job: str = ""
    app_mode: Literal["studio", "covers"] = "studio"
    song_title: str = Field(default="", max_length=300)
    song_artist: str = Field(default="", max_length=300)
    lyrics_source: str = Field(default="", max_length=1000)
    cover_preset: str = Field(default="", max_length=80)
    updated_at: str = ""

    @model_validator(mode="before")
    @classmethod
    def retired_engine(cls, value):
        # Covers saved by the first builds may name the retired PyTorch engine.
        if isinstance(value, dict) and value.get("engine") == "torch":
            value = dict(value, engine="auto")
        return value


class JobRequest(BaseModel):
    kind: Literal["generate", "transcribe"]
    project: Project
    source: str = ""
    resume_from: str = ""

    @model_validator(mode="after")
    def valid_content(self):
        if self.resume_from and (self.kind != "generate" or self.project.takes != 1):
            raise ValueError("Resume saved song tokens as a single music take.")
        if self.kind == "generate":
            if not self.project.style.strip() or not self.project.lyrics.strip():
                raise ValueError("Add a musical style and lyrics first.")
            if self.project.abc.strip() and self.project.cot == "off":
                raise ValueError("A score needs Melody or Melody and harmony.")
            if self.project.cover_source and (
                    not self.project.cover_job or not self.project.abc.strip() or self.project.cot == "off"):
                raise ValueError("Listen to the reference song before creating this cover.")
        if self.kind == "transcribe" and not self.source:
            raise ValueError("Import a reference recording first.")
        return self
