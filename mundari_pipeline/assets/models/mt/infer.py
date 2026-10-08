"""
Standalone Hindi <-> Mundari (Devanagari) Translation Script
Designed to run out of the box with the exported ONNX INT8 model and tokenizer files.

Requirements:
    pip install torch onnxruntime sentencepiece
"""

import os
import sys
import io
import json
import argparse
import numpy as np
import torch
import sentencepiece as spm
import onnxruntime as ort
from transformers import AutoModelForSeq2SeqLM
from transformers.modeling_outputs import BaseModelOutput

# Fix Windows console encoding
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')

BASE_MODEL_REPO = "ai4bharat/indictrans2-indic-indic-dist-320M"


class StandaloneTranslator:
    def __init__(self, bundle_dir="."):
        self.bundle_dir = bundle_dir
        print(f"Initializing Standalone Translator from: {os.path.abspath(bundle_dir)}")

        # 1. Load Tokenizer & Vocabularies
        src_dict_path = os.path.join(bundle_dir, "dict.SRC.json")
        tgt_dict_path = os.path.join(bundle_dir, "dict.TGT.json")
        src_spm_path = os.path.join(bundle_dir, "model.SRC")
        tgt_spm_path = os.path.join(bundle_dir, "model.TGT")

        if not os.path.exists(src_dict_path) or not os.path.exists(src_spm_path):
            raise FileNotFoundError(
                f"Missing tokenizer files in {bundle_dir}! Ensure dict.SRC.json and model.SRC exist."
            )

        with open(src_dict_path, "r", encoding="utf-8") as f:
            self.src_encoder = json.load(f)
        with open(tgt_dict_path, "r", encoding="utf-8") as f:
            self.tgt_encoder = json.load(f)

        self.src_decoder = {v: k for k, v in self.src_encoder.items()}
        self.tgt_decoder = {v: k for k, v in self.tgt_encoder.items()}

        self.src_spm = spm.SentencePieceProcessor(model_file=src_spm_path)
        self.tgt_spm = spm.SentencePieceProcessor(model_file=tgt_spm_path)

        self.pad_token_id = self.src_encoder["<pad>"]
        self.eos_token_id = self.src_encoder["</s>"]
        self.unk_token_id = self.src_encoder["<unk>"]
        self.bos_token_id = self.src_encoder["<s>"]

        # Register custom language tags (mun_Deva -> 122706)
        tags_path = os.path.join(bundle_dir, "tokenizer_custom_tags.json")
        if os.path.exists(tags_path):
            with open(tags_path, "r", encoding="utf-8") as f:
                tag_meta = json.load(f)
            for tag, tid in tag_meta.get("added_tags", {}).items():
                self.src_encoder[tag] = tid
                self.src_decoder[tid] = tag
        elif "mun_Deva" not in self.src_encoder:
            self.src_encoder["mun_Deva"] = 122706
            self.src_decoder[122706] = "mun_Deva"

        print("  Tokenizer & custom tag 'mun_Deva' registered successfully.")

        # 2. Load INT8 ONNX Encoder
        onnx_model_path = os.path.join(bundle_dir, "model_int8.onnx")
        if not os.path.exists(onnx_model_path):
            onnx_model_path = os.path.join(bundle_dir, "indictrans2_encoder_int8.onnx")

        print(f"  Loading INT8 ONNX Encoder: {onnx_model_path}")
        sess_opts = ort.SessionOptions()
        sess_opts.intra_op_num_threads = 1
        sess_opts.inter_op_num_threads = 1
        self.ort_session = ort.InferenceSession(
            onnx_model_path, sess_opts, providers=["CPUExecutionProvider"]
        )

        # 3. Load Decoder for Autoregressive Generation
        print(f"  Loading decoder architecture from {BASE_MODEL_REPO}...")
        self.model = AutoModelForSeq2SeqLM.from_pretrained(
            BASE_MODEL_REPO, trust_remote_code=True, attn_implementation="eager"
        )
        self.model.config.use_cache = True
        if hasattr(self.model, "generation_config") and self.model.generation_config is not None:
            self.model.generation_config.use_cache = True
            self.model.generation_config.return_legacy_cache = True

        # Align vocabulary configs
        old_embeds = self.model.model.encoder.embed_tokens
        new_embeds = torch.nn.Embedding(122707, old_embeds.weight.shape[1], padding_idx=old_embeds.padding_idx)
        with torch.no_grad():
            new_embeds.weight[:122706] = old_embeds.weight
            new_embeds.weight[122706] = old_embeds.weight[8].clone()
        self.model.model.encoder.embed_tokens = new_embeds
        self.model.config.encoder_vocab_size = 122707
        self.model.config.vocab_size = 122672
        self.model.config.decoder_vocab_size = 122672
        self.model.eval()

        print("✅ Standalone Translator initialized and ready for inference!\n")

    def encode_src(self, text, max_length=128):
        parts = text.strip().split(" ", 2)
        if len(parts) == 3:
            src_lang, tgt_lang, actual_text = parts
        else:
            src_lang, tgt_lang, actual_text = "hin_Deva", "mun_Deva", text

        src_id = self.src_encoder.get(src_lang, self.unk_token_id)
        tgt_id = self.src_encoder.get(tgt_lang, self.unk_token_id)
        pieces = self.src_spm.EncodeAsPieces(actual_text)
        piece_ids = [self.src_encoder.get(p, self.unk_token_id) for p in pieces]

        token_ids = [src_id, tgt_id] + piece_ids + [self.eos_token_id]
        if len(token_ids) > max_length:
            token_ids = token_ids[: max_length - 1] + [self.eos_token_id]
        return token_ids

    def decode(self, token_ids, skip_special_tokens=True):
        if isinstance(token_ids, torch.Tensor):
            token_ids = token_ids.tolist()
        tokens = []
        special_ids = {self.pad_token_id, self.eos_token_id, self.bos_token_id, self.unk_token_id}
        for tid in token_ids:
            if skip_special_tokens and tid in special_ids:
                continue
            if tid in self.tgt_decoder:
                tokens.append(self.tgt_decoder[tid])
        return self.tgt_spm.DecodePieces(tokens)

    def translate(self, text, direction="hin2mun", max_length=128, num_beams=1):
        if direction in ["hin2mun", "hindi2mundari"]:
            src_tag, tgt_tag = "hin_Deva", "mun_Deva"
        elif direction in ["mun2hin", "mundari2hindi"]:
            src_tag, tgt_tag = "mun_Deva", "hin_Deva"
        else:
            raise ValueError(f"Unknown direction '{direction}'. Use 'hin2mun' or 'mun2hin'.")

        formatted = f"{src_tag} {tgt_tag} {text.strip()}"
        raw_ids = self.encode_src(formatted, max_length)
        in_ids = torch.tensor([raw_ids])
        in_mask = torch.ones_like(in_ids)

        # 1. INT8 ONNX Encoder Forward Pass
        ort_outs = self.ort_session.run(
            None, {"input_ids": in_ids.numpy(), "attention_mask": in_mask.numpy()}
        )
        enc_hidden = torch.from_numpy(ort_outs[0])

        # 2. Decoder Generation
        enc_output = BaseModelOutput(last_hidden_state=enc_hidden)
        with torch.no_grad():
            gen = self.model.generate(
                encoder_outputs=enc_output,
                attention_mask=in_mask,
                max_length=max_length,
                num_beams=num_beams,
                use_cache=True,
                return_legacy_cache=True,
            )

        return self.decode(gen[0])


def main():
    parser = argparse.ArgumentParser(description="Standalone Hindi <-> Mundari (Devanagari) Translator")
    parser.add_argument("--bundle_dir", default=".", help="Path to unzipped model bundle directory")
    parser.add_argument("--text", type=str, help="Text to translate")
    parser.add_argument("--direction", choices=["hin2mun", "mun2hin"], default="hin2mun", help="Translation direction")
    parser.add_argument("--num_beams", type=int, default=1, help="Beam size (1=greedy, 4=beam search)")
    parser.add_argument("--interactive", action="store_true", help="Start interactive terminal mode")
    args = parser.parse_args()

    translator = StandaloneTranslator(bundle_dir=args.bundle_dir)

    if args.text:
        result = translator.translate(args.text, direction=args.direction, num_beams=args.num_beams)
        print(f"\n[Source ({args.direction})]: {args.text}")
        print(f"[Translation]:         {result}\n")
    elif args.interactive or not args.text:
        print("=== Interactive Translation Mode (Type 'exit' to quit) ===")
        print("Default direction: hin2mun (Hindi -> Mundari Devanagari)")
        print("Type ':switch' to toggle direction.\n")
        current_dir = args.direction
        while True:
            try:
                prompt = f"[{current_dir}] > "
                user_input = input(prompt).strip()
                if not user_input:
                    continue
                if user_input.lower() in ["exit", "quit", "q"]:
                    break
                if user_input.lower() == ":switch":
                    current_dir = "mun2hin" if current_dir == "hin2mun" else "hin2mun"
                    print(f"Switched direction to: {current_dir}\n")
                    continue

                trans = translator.translate(user_input, direction=current_dir, num_beams=args.num_beams)
                print(f"-> {trans}\n")
            except (KeyboardInterrupt, EOFError):
                break


if __name__ == "__main__":
    main()
