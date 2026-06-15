# Software golden for final tests 02 and 05

This directory models the exact inference contract used by:

- `dma/final_tests/02_mydesign_inference.py`
- `dma/final_tests/05_apu_dma_inference.py`

It intentionally does not use the RTL testbench vectors, `data/param_files`,
or `data/data_flow`.

Generate the ideal result on the PC:

```powershell
python dma\sw\ideal_inference.py
```

Compare captures produced by final tests 02 and 05:

```bash
python3 dma/sw/compare_hardware.py
```

Locate the first failing hardware layer without changing RTL:

```bash
python3 dma/sw/diagnose_dma_stages.py
python3 dma/sw/diagnose_dma_prefixes.py
python3 dma/sw/diagnose_dma_prefixes.py --prefix 6
```

Generated files are written to `dma/sw/output/`. The ideal APU tensors use
canonical NCHW channel order and the same 0/1 convention as
`apuYjb/resnet_binary_ps.py`: positive is 0 and negative is 1.
