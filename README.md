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


