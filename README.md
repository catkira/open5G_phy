[![Verify](https://github.com/catkira/5G_SSB_sync/actions/workflows/verify.yml/badge.svg)](https://github.com/catkira/5G_SSB_sync/actions/workflows/verify.yml)

# Overview
This is a verilog HDL core for 5G SSB synchronization optimized for low ressource usage so that it can run on a [PlutoSDR](https://www.analog.com/en/design-center/evaluation-hardware-and-software/evaluation-boards-kits/adalm-pluto.html), which has a Xilinx® Zynq Z-7010 with only 80 DSP slices and 28K logic cells.<br>
Each PSS correlator only detects one of the possible three different PSS sequences. If a general cell search is needed, 3 PSS correlators need to be instanciated in parallel. If CFOs larger than one subcarrier spacing (15 kHz) are expected, more parallel PSS correlator instances are needed for different CFOs.<br>
Implemented so far:<br>
* Decimator which uses [this](https://github.com/catkira/CIC) CIC core
* PSS correlator (detailed description below)
* Peak detector (detailed description below)
* FFT demodulator which uses [this](https://github.com/catkira/FFT) FFT core
* SSS detector (detailed description below)

![Overview diagram](doc/overview.jpg)

<b>TODO:</b>
* channel estimator using PBCH DMRS and SSS
* PBCH demodulator
* maybe optimize PSS correlator further like described [here](https://ieeexplore.ieee.org/document/8641097) or [here](https://ieeexplore.ieee.org/document/9312170)

# Ressource usage
* Decimator       :  0 DSP slices
* PSS correlator  :  6 DSP slices (with MULT_REUSE=64)
* Peak detector   :  0 DSP slices
* FFT demodulator :  ? DSP slices
* SSS detector    :  ? DSP slices

# Tests
```
  sudo apt install iverilog
  pip install -e requirements.txt
  git clone https://github.com/catkira/cocotb.git
  cd cocotb && pip install -e . && cd ..
  pytest --workers 8
```

# Decimator
The incoming sample rate to the SSB_sync module should be 3.84 MSPS. This sample rate is then internally decimated to 1.92 MSPS so that the PSS and SSS detection cores can run most efficiently.
The PBCH demodulation core needs 3.84 MSPS. Decimation is done by a CIC core which does not need any multiplications.

# PSS correlator
Without optimizations the PSS correlator would require 128 * 3 + 2 real multipliers, 3 real multipliers for each complex multiplication and 2 real multipliers for calculation of the absolute value. This can be further optimized by taking into account that the PSS sequence in time domain is real valued. Therefore the PSS sequence in frequency domain is complex conjugate centrally symmetric. This can be used to reduce the required number of real multipliers to 128 * 2 + 2 as shown in [this](https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=8641097) paper. <br>
Further optimization can be achieved when taking into account that the sample rate for the SSB is only 3.84 MSPS (with 15 KHz SCS) and the PSS and SSB detection cores only need a sample rate of 1.92 MSPS. If the PSS correlator runs on a 122.88 Mhz clock, a single multiplier can be used to perform 64 multiplications at 1.92 MSPS. This feature is already implemented into the PSS correlator (PSS_correlator_mr.v) and can be adjusted by changing the MULT_REUSE parameter. <br>
For a sample rate of 1.92 MSPS and a clock rate of 122.88 MHz, the PSS correlator requires 2 * 2 + 2 real multipliers. <br><br>
The PSS correlator core supports variable widths for the data input (IN_DW), for the PSS coefficients (TAP_DW) and for the output (OUT_DW). The bit growth from input to output can be described as IN_DW + TAP_DW + 2 + 2 * ceil(log2(PSS_LEN)). If OUT_DW is not large enough to receive the whole bit growth, the output will be truncated so that only some LSBs get lost. However, in that case there will be unnecessary many ressources used, therefore it is recommended to configure the core in such a way that no truncation is needed. Since IN_DW and TAP_DW are widths for complex numbers, they have to be even numbers so that the real and imaginary part can have equal widths. <br>
A sensible configuration would be: <br>
   IN_DW = 14 (signed I and Q) <br>
   TAP_DW = 18 (signed I and Q) <br>
   OUT_DW = 48 (unsigned) <br>
Calculation the growth gives: 16 + 16 + 2 + 2 * 7 = 48 <br>
This would allow DSP48E1 slices to be used, even for the last multipliers that are used to calculate the absolute value. IN_DW is chosen a bit smaller than TAP_DW, because the last LSBs of input data are usually just noise.
<br><br>
<b>TODO:</b> pipelining

# Peak detector
The peak detector takes the sum of the last WINDOW_LEN samples and compares it to the current sample. If the current sample is larger than the window sum times a DETECTION_FACTOR, then a peak is detected. DETECTION_FACTOR is currently hard coded to 32, so that the multiplication can be implemented as a shift operation. As result, this core only needs WINDOW_LEN additions and no multiplications. <br><br>
<b>TODO:</b> There is currently no pipelining implemented. For larger windows it is probably needed to break up the add operation into different stages.

# FFT demodulator
The FFT demodulator uses [this](https://github.com/catkira/FFT). Since the core runs at 122.88 MHz while the sample rate it only 3.84 MSPS, overclocking can be used to reduce the number of required multipliers. Normally a FFT would need 3 real multipliers per stage, with overclocking this can be reduced to 1 multiplier per stage. SSS would only need a 128 point FFT, but a 256 point FFT is used anyway, so that it can also be used for PBCH demodulation. This results in 8 real multipliers required for the FFT. The FFT demodulator is synchronized to the start signal from the Peak detector. It then continuously performs FFTs. There are special tag signals for the start of the SSS and PBCH symbols.

# SSS demodulator
The SSS detector currently operates in search mode, which means that it compares the received SSS sequence to all possible 335 SSS for the given N_id_1 which comes from the PSS detection.
The code is optimized to not use any multiplication and no large additions. This is achieved by doing every operation in a separate clock cycle. This means the core needs about 335 * 127 = 42545 cycles to finish the detection, assuming the system clock is 100 MHz, that would be 425 us.
The code is also memory optimized, by only storing the two m-sequences that are needed to construct all the possible SSS. It currently builds the stored m-sequences at startup using [this](https://github.com/catkira/LFSR) LFSR core. The code could be modified to have the m-sequences statically stored.
