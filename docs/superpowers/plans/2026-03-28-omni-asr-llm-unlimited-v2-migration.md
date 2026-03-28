# omniASR LLM Unlimited v2 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace all omniASR model references with the `omniASR_LLM_Unlimited_*_v2` family, migrating any saved user settings automatically.

**Architecture:** Extend the existing migration match in `AppSettings::load_from` to cover old CTC and unversioned LLM names, update the default, and replace the 6-item frontend options array with the 4 v2 Unlimited entries. No changes to the Python worker or Rust transcription engine — they accept model names as opaque strings.

**Tech Stack:** Rust (serde_json, tempfile for tests), TypeScript/React

---

## File Map

| File | Action |
|---|---|
| `crates/opencassava-core/src/settings.rs` | Modify default fn + migration match + add test |
| `opencassava/src/components/SettingsView.tsx` | Modify `omniAsrModelOptions` array |

---

### Task 1: Write failing migration test

**Files:**
- Modify: `crates/opencassava-core/src/settings.rs` (test module, ~line 500)

- [ ] **Step 1: Add the failing test to the `#[cfg(test)]` block at the bottom of `settings.rs`**

Append inside the existing `mod tests { ... }` block (after the last `}` of the last test, before the closing `}` of the module):

```rust
    #[test]
    fn omni_asr_model_migrates_to_v2() {
        let cases: &[(&str, &str)] = &[
            // Legacy HuggingFace-style names
            ("facebook/omnilingual-asr-300m", "omniASR_LLM_Unlimited_300M_v2"),
            ("omnilingual-asr-300m",          "omniASR_LLM_Unlimited_300M_v2"),
            ("facebook/omnilingual-asr-1b",   "omniASR_LLM_Unlimited_1B_v2"),
            ("omnilingual-asr-1b",            "omniASR_LLM_Unlimited_1B_v2"),
            ("facebook/omnilingual-asr-3b",   "omniASR_LLM_Unlimited_3B_v2"),
            ("omnilingual-asr-3b",            "omniASR_LLM_Unlimited_3B_v2"),
            ("facebook/omnilingual-asr-7b",   "omniASR_LLM_Unlimited_7B_v2"),
            ("omnilingual-asr-7b",            "omniASR_LLM_Unlimited_7B_v2"),
            // Old CTC names
            ("omniASR_CTC_300M", "omniASR_LLM_Unlimited_300M_v2"),
            ("omniASR_CTC_1B",   "omniASR_LLM_Unlimited_1B_v2"),
            ("omniASR_CTC_3B",   "omniASR_LLM_Unlimited_3B_v2"),
            // Old unversioned LLM names
            ("omniASR_LLM_300M", "omniASR_LLM_Unlimited_1B_v2"),
            ("omniASR_LLM_1B",   "omniASR_LLM_Unlimited_3B_v2"),
            ("omniASR_LLM_7B",   "omniASR_LLM_Unlimited_7B_v2"),
            // v2 Unlimited names pass through unchanged
            ("omniASR_LLM_Unlimited_300M_v2", "omniASR_LLM_Unlimited_300M_v2"),
            ("omniASR_LLM_Unlimited_1B_v2",   "omniASR_LLM_Unlimited_1B_v2"),
            ("omniASR_LLM_Unlimited_3B_v2",   "omniASR_LLM_Unlimited_3B_v2"),
            ("omniASR_LLM_Unlimited_7B_v2",   "omniASR_LLM_Unlimited_7B_v2"),
        ];

        for (old, expected) in cases {
            let dir = tempdir().unwrap();
            let path = dir.path().join("settings.json");
            std::fs::write(
                &path,
                format!(r#"{{"omniAsrModel": "{}"}}"#, old),
            )
            .unwrap();
            let s = AppSettings::load_from(path);
            assert_eq!(
                s.omni_asr_model, *expected,
                "expected '{}' to migrate to '{}', got '{}'",
                old, expected, s.omni_asr_model
            );
        }
    }
```

- [ ] **Step 2: Run the test — confirm it fails**

```
cargo test -p opencassava-core omni_asr_model_migrates_to_v2 -- --nocapture
```

Expected: FAIL — several assertions fail because old CTC/LLM names aren't yet mapped to v2 names.

---

### Task 2: Update the migration map in `settings.rs`

**Files:**
- Modify: `crates/opencassava-core/src/settings.rs` (lines 147–155)

- [ ] **Step 3: Replace the migration match block**

Find this block (lines 147–155):

```rust
        // Migrate old HuggingFace-style omni-asr model names to fairseq2 card names.
        s.omni_asr_model = match s.omni_asr_model.as_str() {
            "facebook/omnilingual-asr-300m" | "omnilingual-asr-300m" => "omniASR_CTC_300M",
            "facebook/omnilingual-asr-1b" | "omnilingual-asr-1b" => "omniASR_CTC_1B",
            "facebook/omnilingual-asr-3b" | "omnilingual-asr-3b" => "omniASR_CTC_3B",
            "facebook/omnilingual-asr-7b" | "omnilingual-asr-7b" => "omniASR_LLM_7B",
            other => other,
        }
        .to_string();
```

Replace with:

```rust
        // Migrate old model names (HuggingFace-style, CTC, unversioned LLM) to
        // omniASR_LLM_Unlimited_*_v2 card names.
        s.omni_asr_model = match s.omni_asr_model.as_str() {
            "facebook/omnilingual-asr-300m" | "omnilingual-asr-300m" | "omniASR_CTC_300M" => {
                "omniASR_LLM_Unlimited_300M_v2"
            }
            "facebook/omnilingual-asr-1b"
            | "omnilingual-asr-1b"
            | "omniASR_CTC_1B"
            | "omniASR_LLM_300M" => "omniASR_LLM_Unlimited_1B_v2",
            "facebook/omnilingual-asr-3b"
            | "omnilingual-asr-3b"
            | "omniASR_CTC_3B"
            | "omniASR_LLM_1B" => "omniASR_LLM_Unlimited_3B_v2",
            "facebook/omnilingual-asr-7b" | "omnilingual-asr-7b" | "omniASR_LLM_7B" => {
                "omniASR_LLM_Unlimited_7B_v2"
            }
            other => other,
        }
        .to_string();
```

- [ ] **Step 4: Run the migration test — confirm it passes**

```
cargo test -p opencassava-core omni_asr_model_migrates_to_v2 -- --nocapture
```

Expected: PASS (all 18 cases).

---

### Task 3: Update the default model in `settings.rs`

**Files:**
- Modify: `crates/opencassava-core/src/settings.rs` (line 240–242)

- [ ] **Step 5: Change `default_omni_asr_model`**

Find:

```rust
fn default_omni_asr_model() -> String {
    "omniASR_CTC_300M".into()
}
```

Replace with:

```rust
fn default_omni_asr_model() -> String {
    "omniASR_LLM_Unlimited_1B_v2".into()
}
```

- [ ] **Step 6: Run all settings tests — confirm nothing regressed**

```
cargo test -p opencassava-core settings -- --nocapture
```

Expected: all tests PASS (the new default is valid and will pass through the `other => other` arm of the migration match).

- [ ] **Step 7: Commit**

```bash
git add crates/opencassava-core/src/settings.rs
git commit -m "feat: migrate omniASR to LLM_Unlimited_*_v2 family"
```

---

### Task 4: Update the frontend model options in `SettingsView.tsx`

**Files:**
- Modify: `opencassava/src/components/SettingsView.tsx` (lines 71–78)

- [ ] **Step 8: Replace `omniAsrModelOptions`**

Find:

```typescript
const omniAsrModelOptions = [
  { value: "omniASR_CTC_300M",  label: "omniASR CTC 300M (Fast)",     description: "300M CTC model — fastest, good for most languages." },
  { value: "omniASR_CTC_1B",    label: "omniASR CTC 1B",              description: "1B CTC model — better accuracy, 1,600+ languages." },
  { value: "omniASR_CTC_3B",    label: "omniASR CTC 3B",              description: "3B CTC model — high accuracy." },
  { value: "omniASR_LLM_300M",  label: "omniASR LLM 300M",            description: "300M LLM model — language-conditioned transcription." },
  { value: "omniASR_LLM_1B",    label: "omniASR LLM 1B",              description: "1B LLM model — improved multilingual quality." },
  { value: "omniASR_LLM_7B",    label: "omniASR LLM 7B (Best)",       description: "7B LLM model — highest accuracy, requires more VRAM." },
];
```

Replace with:

```typescript
const omniAsrModelOptions = [
  { value: "omniASR_LLM_Unlimited_300M_v2", label: "omniASR LLM Unlimited 300M v2 (Fast)", description: "Fastest unlimited-length model." },
  { value: "omniASR_LLM_Unlimited_1B_v2",   label: "omniASR LLM Unlimited 1B v2",          description: "Balanced speed and accuracy." },
  { value: "omniASR_LLM_Unlimited_3B_v2",   label: "omniASR LLM Unlimited 3B v2",          description: "High accuracy." },
  { value: "omniASR_LLM_Unlimited_7B_v2",   label: "omniASR LLM Unlimited 7B v2 (Best)",   description: "Highest accuracy, requires more VRAM." },
];
```

- [ ] **Step 9: Verify TypeScript compiles (no type errors)**

```
cd opencassava && npm run build 2>&1 | head -40
```

Expected: build succeeds with no TypeScript errors related to the model options.

- [ ] **Step 10: Commit**

```bash
git add opencassava/src/components/SettingsView.tsx
git commit -m "feat: update omniASR UI options to LLM_Unlimited_*_v2 family"
```
