"""Shared NuExtract3-OCR model loader.

Used by pdf.py (multi-page render) and image.py (single image / multi-frame
TIFF). Lazy-loads on first call so non-image inputs (txt/md/docx) don't pay
the GPU-load cost.
"""

from __future__ import annotations

import os

NUEXTRACT_MODEL = os.getenv("NUEXTRACT_MODEL", "numind/NuExtract3")
MAX_NEW_TOKENS = int(os.getenv("OCR_MAX_NEW_TOKENS", "4096"))
OCR_PROMPT = (
    "Convert this document page to clean Markdown. Preserve headings, lists, and "
    "tables (use HTML tables for complex layouts). Transcribe text verbatim, "
    "including handwriting and misspellings. Output only the Markdown."
)


class OCRModel:
    """Singleton-ish: instantiate once per worker process."""

    _instance = None

    @classmethod
    def get(cls) -> "OCRModel":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def __init__(self):
        import torch
        from transformers import AutoModelForImageTextToText, AutoProcessor

        if torch.cuda.is_available():
            self.device, dtype = "cuda", torch.bfloat16
        elif torch.backends.mps.is_available():
            self.device, dtype = "mps", torch.float16
        else:
            self.device, dtype = "cpu", torch.float32
        print(f"[load] NuExtract3 on {self.device} ({dtype})", flush=True)
        self.torch = torch
        self.processor = AutoProcessor.from_pretrained(NUEXTRACT_MODEL, trust_remote_code=True)
        self.model = (
            AutoModelForImageTextToText
            .from_pretrained(NUEXTRACT_MODEL, dtype=dtype, trust_remote_code=True)
            .to(self.device).eval()
        )

    def ocr_page(self, image) -> str:
        """One PIL image → markdown string."""
        inputs = self.processor.apply_chat_template(
            [{"role": "user", "content": [
                {"type": "image", "image": image}, {"type": "text", "text": OCR_PROMPT}]}],
            add_generation_prompt=True, tokenize=True, return_tensors="pt", return_dict=True,
        ).to(self.device)
        with self.torch.inference_mode():
            out = self.model.generate(**inputs, max_new_tokens=MAX_NEW_TOKENS, do_sample=False)
        new = out[0][inputs["input_ids"].shape[-1]:]
        return self.processor.decode(new, skip_special_tokens=True).strip()
