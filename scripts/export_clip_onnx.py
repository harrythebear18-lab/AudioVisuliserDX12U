#!/usr/bin/env python3
"""
Export OpenAI CLIP ViT-B/32 to ONNX format for inline C# inference.

Usage:
    pip install torch transformers onnx
    python export_clip_onnx.py

Output files (copy to RTXAudioVisualizer/models/clip/):
    clip_image_encoder.onnx
    clip_text_encoder.onnx
    clip_vocab.json
    clip_merges.txt
"""

import json
import os
import shutil
import sys

import torch
from transformers import CLIPModel, CLIPTokenizer

OUTPUT_DIR = os.path.dirname(os.path.abspath(__file__))
MODELS_DIR = os.path.join(OUTPUT_DIR, "..", "models", "clip")
MODEL_NAME = "openai/clip-vit-base-patch32"
SEQ_LEN = 77
EMBED_DIM = 512


def export_image_encoder(model, output_path):
    """Export CLIP vision model to ONNX — input: pixel_values (1,3,224,224) float32"""

    class ImageEncoderWrapper(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.vision_model = clip_model.vision_model
            self.visual_projection = clip_model.visual_projection

        def forward(self, pixel_values):
            outputs = self.vision_model(pixel_values=pixel_values)
            pooled = outputs.pooler_output  # (1, 768)
            return self.visual_projection(pooled)  # (1, 512)

    wrapper = ImageEncoderWrapper(model).eval()
    dummy = torch.randn(1, 3, 224, 224)

    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            dummy,
            output_path,
            input_names=["pixel_values"],
            output_names=["image_embeds"],
            dynamic_axes={
                "pixel_values": {0: "batch"},
                "image_embeds": {0: "batch"},
            },
            opset_version=17,
            do_constant_folding=True,
            dynamo=False,
        )
    print(f"  Image encoder: {output_path} ({os.path.getsize(output_path) / 1e6:.1f} MB)")


def export_text_encoder(model, output_path):
    """Export CLIP text model to ONNX — inputs: input_ids (1,77) int64, attention_mask (1,77) int64"""

    class TextEncoderWrapper(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.text_model = clip_model.text_model
            self.text_projection = clip_model.text_projection

        def forward(self, input_ids, attention_mask):
            outputs = self.text_model(
                input_ids=input_ids, attention_mask=attention_mask
            )
            pooled = outputs.pooler_output  # (1, 512) for base model
            return self.text_projection(pooled)  # (1, 512)

    wrapper = TextEncoderWrapper(model).eval()
    dummy_ids = torch.randint(0, 49408, (1, SEQ_LEN), dtype=torch.long)
    dummy_mask = torch.ones(1, SEQ_LEN, dtype=torch.long)

    with torch.no_grad():
        torch.onnx.export(
            wrapper,
            (dummy_ids, dummy_mask),
            output_path,
            input_names=["input_ids", "attention_mask"],
            output_names=["text_embeds"],
            dynamic_axes={
                "input_ids": {0: "batch"},
                "attention_mask": {0: "batch"},
                "text_embeds": {0: "batch"},
            },
            opset_version=17,
            do_constant_folding=True,
            dynamo=False,
        )
    print(f"  Text encoder: {output_path} ({os.path.getsize(output_path) / 1e6:.1f} MB)")


def copy_tokenizer_files(tokenizer, dest_dir):
    """Copy vocab.json and merges.txt from the HuggingFace tokenizer."""
    vocab_path = os.path.join(dest_dir, "clip_vocab.json")
    merges_path = os.path.join(dest_dir, "clip_merges.txt")

    # Save vocab
    vocab = tokenizer.get_vocab()
    with open(vocab_path, "w", encoding="utf-8") as f:
        json.dump(vocab, f, ensure_ascii=False)
    print(f"  Vocab: {vocab_path} ({len(vocab)} entries)")

    # Copy merges file
    merges_src = os.path.join(
        os.path.dirname(tokenizer.vocab_file) if hasattr(tokenizer, "vocab_file") else "",
        "merges.txt",
    )
    # Fallback: use the tokenizer's saved files
    if not os.path.exists(merges_src):
        # Save tokenizer to temp dir and get merges from there
        tmp_dir = os.path.join(dest_dir, "_tmp_tokenizer")
        tokenizer.save_pretrained(tmp_dir)
        merges_src = os.path.join(tmp_dir, "merges.txt")

    shutil.copy2(merges_src, merges_path)
    print(f"  Merges: {merges_path}")

    # Cleanup temp
    tmp_dir = os.path.join(dest_dir, "_tmp_tokenizer")
    if os.path.exists(tmp_dir):
        shutil.rmtree(tmp_dir)


def main():
    os.makedirs(MODELS_DIR, exist_ok=True)

    print(f"Loading {MODEL_NAME}...")
    model = CLIPModel.from_pretrained(MODEL_NAME)
    tokenizer = CLIPTokenizer.from_pretrained(MODEL_NAME)
    model.eval()
    print(f"  Model loaded. Vision dim={model.config.vision_config.hidden_size}, "
          f"Text dim={model.config.text_config.hidden_size}, "
          f"Projection={model.config.projection_dim}")

    print("\nExporting ONNX models:")
    export_image_encoder(model, os.path.join(MODELS_DIR, "clip_image_encoder.onnx"))
    export_text_encoder(model, os.path.join(MODELS_DIR, "clip_text_encoder.onnx"))

    print("\nCopying tokenizer files:")
    copy_tokenizer_files(tokenizer, MODELS_DIR)

    # Verify with a quick test
    print("\nVerifying ONNX models...")
    try:
        import onnxruntime as ort

        # Test image encoder
        img_session = ort.InferenceSession(
            os.path.join(MODELS_DIR, "clip_image_encoder.onnx")
        )
        dummy_img = torch.randn(1, 3, 224, 224).numpy()
        img_out = img_session.run(None, {"pixel_values": dummy_img})
        print(f"  Image encoder output shape: {img_out[0].shape}")

        # Test text encoder
        text_session = ort.InferenceSession(
            os.path.join(MODELS_DIR, "clip_text_encoder.onnx")
        )
        tokens = tokenizer("a 3D music visualizer", max_length=SEQ_LEN,
                          padding="max_length", truncation=True, return_tensors="pt")
        text_out = text_session.run(
            None,
            {
                "input_ids": tokens["input_ids"].numpy(),
                "attention_mask": tokens["attention_mask"].numpy(),
            },
        )
        print(f"  Text encoder output shape: {text_out[0].shape}")

        # Cosine similarity test
        import numpy as np
        img_emb = img_out[0].flatten()
        text_emb = text_out[0].flatten()
        print(f"  Image embed shape: {img_emb.shape}, Text embed shape: {text_emb.shape}")
        if img_emb.shape == text_emb.shape:
            img_emb = img_emb / np.linalg.norm(img_emb)
            text_emb = text_emb / np.linalg.norm(text_emb)
            sim = float(np.dot(img_emb, text_emb))
            print(f"  Random image vs text similarity: {sim:.4f} (expect ~0.0 for random)")
        else:
            print(f"  WARNING: Shape mismatch — image {img_emb.shape} vs text {text_emb.shape}")
            print(f"  Models may need re-export with correct pooling")

        print(f"\n✓ All models exported to {MODELS_DIR}")
        print(f"  Files: clip_image_encoder.onnx, clip_text_encoder.onnx, clip_vocab.json, clip_merges.txt")
    except ImportError:
        print("\n  (onnxruntime not installed — skipping verification. pip install onnxruntime to verify.)")
        print(f"\n✓ Models exported to {MODELS_DIR}")


if __name__ == "__main__":
    main()
