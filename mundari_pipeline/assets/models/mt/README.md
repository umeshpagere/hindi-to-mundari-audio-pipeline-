# Hindi ↔ Mundari (Devanagari) INT8 ONNX Model Bundle

This bundle contains the fine-tuned, INT8 quantized ONNX encoder and standalone inference pipeline for bidirectional **Hindi (`hin_Deva`) ↔ Mundari in Devanagari script (`mun_Deva`)** machine translation.

---

## 📦 Bundle Contents

| File | Size | Description |
| :--- | :--- | :--- |
| `model_int8.onnx` | ~116 MB | Dynamic INT8 quantized ONNX encoder |
| `tokenizer_custom_tags.json` | < 1 KB | Tag registry registering `mun_Deva` (ID: 122706) |
| `dict.SRC.json` | 3.39 MB | Source subword vocabulary |
| `dict.TGT.json` | 3.39 MB | Target subword vocabulary (122,672 tokens) |
| `model.SRC` | 3.25 MB | Source SentencePiece model |
| `model.TGT` | 3.25 MB | Target SentencePiece model |
| `config.json` | 1.3 KB | Base architecture & vocabulary configuration |
| `infer.py` | 7.5 KB | Self-contained Python inference script |
| `final_deployment_report.md` | 3.2 KB | Benchmark & evaluation report (BLEU, chrF++, Latency, RAM) |

---

## 🚀 Quickstart Usage

### 1. Install Requirements
```bash
pip install torch onnxruntime sentencepiece
```

### 2. Run Translation

#### Hindi to Mundari (Devanagari):
```bash
python infer.py --direction hin2mun --text "भारत एक बहुत सुंदर देश है।"
```

#### Mundari (Devanagari) to Hindi:
```bash
python infer.py --direction mun2hin --text "दिशुम रेन होड़ोको सोबेन मिद् ते मेनाकवा।"
```

#### Interactive Terminal Mode:
```bash
python infer.py --interactive
```

---

## 📊 Key Specifications
* **Base Architecture**: `ai4bharat/indictrans2-indic-indic-dist-320M`
* **Quantization**: Dynamic INT8 (QuantType.QUInt8)
* **Working RAM Footprint**: **~183 MB** (well within 400 MB mobile limits)
* **Single-Thread CPU Latency**:
  * Short sentences (6 words): **~0.31s**
  * Medium sentences (18 words): **~0.77s**
  * Long sentences (35 words): **~1.04s**
* **Test Set Performance (Unseen 1,992 sentence pairs)**:
  * Hindi $\rightarrow$ Mundari (Devanagari): **BLEU: 10.68 | chrF++: 5.17**
  * Mundari (Devanagari) $\rightarrow$ Hindi: **BLEU: 17.97 | chrF++: 6.92**
* **Script Rule**: 100% Devanagari script for both Hindi and Mundari (0 Odia script characters).
