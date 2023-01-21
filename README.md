[![Verify](https://github.com/catkira/5G_SSB_sync/actions/workflows/verify.yml/badge.svg)](https://github.com/catkira/5G_SSB_sync/actions/workflows/verify.yml)

# 5G_SSB_sync
HDL code for 5G SSB synchronization.<br>
Implemented so far:<br>
* Decimator which uses my [CIC core](https://github.com/catkira/CIC)
* PSS correlator (optimized to by reusing multipliers)
* Peak detector still very simple
* SSS Demodulator which uses [ZipCPU's FFT core](https://github.com/ZipCPU/dblclockfft)

TODO:
* SSS detector
* channel estimator
* PBCH demodulator
* maybe optimize PSS correlator furtherlike described [here](https://ieeexplore.ieee.org/document/8641097) or [here](https://ieeexplore.ieee.org/document/9312170)

# Tests
```
  sudo apt install iverilog
  pip install -e requirements.txt
  git clone https://github.com/catkira/cocotb.git
  cd cocotb && pip install -e . && cd ..
  pytest --workers 8
```

# PSS correlator
Without optimizations the PSS correlator would require 128 * 3 + 2 real multipliers, 3 real multipliers for each complex multiplication and 2 real multipliers for calculation of the absolute value. This can be further optimized by taking into account that the PSS sequence in time domain is real valued. Therefore the PSS sequence in frequency domain is complex conjugate centrally symmetric. This can be used to reduce the required number of real multipliers to 128 * 2 + 2 as shown in [this](https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=8641097) paper. <br>
Further optimization can be achieved when taking into account that the sample rate for the SSB is only 3.84 MSPS (with 15 KHz SCS). If the PSS correlator runs on a 122.88 Mhz clock, a single multiplier can be used to perform 32 multiplications at 3.84 MSPS. This feature is already implemented into the PSS correlator (PSS_correlator_mr.v) and can be adjusted by changing the MULT_REUSE parameter. <br>
For a sample rate of 3.84 MSPS and a clock rate of 122.88 MHz, the PSS correlator requires 4 * 2 + 2 real multipliers. <br>
The PSS correlator core supports variable widths for the data input (IN_DW), for the PSS coefficients (TAP_DW) and for the output (OUT_DW). The bit growth from input to output can be described as IN_DW + TAP_DW + 2 + 2 * ceil(log2(PSS_LEN)) + 1. If OUT_DW is not large enough to receive the whole bit growth, the output will be truncated so that only some LSBs get lost. However, in that case there will be unnecessary many ressources used, therefore it is recommended to configure the core in such a way that no truncation is needed. <br>
A sensible configuration would be: <br>
   IN_DW = 12 (signed) <br>
   TAP_DW = 16 (signed) <br>
   OUT_DW = 45 (unsigned) <br>
Calculation the growth gives: 12 + 16 + 2 + 2 * 7 + 1 = 45 <br>
This would allow DSP48E1 slices to be used, even for the last multipliers that are used to calculate the absolute value. IN_DW is chosen a bit smaller than TAP_DW, because the last LSBs of input data are usually just noise.
