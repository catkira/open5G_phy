[![Verify](https://github.com/catkira/open5G_rx/actions/workflows/verify.yml/badge.svg)](https://github.com/catkira/open5G_rx/actions/workflows/verify.yml)

<b>
Note: This documentation and code is out-dated and not supported anymore. The missing FFT submodule dependency has been fixed. All CI tests pass. Client tools like open5G_tools are not available anymore since they were not GPL licensed.
</b>
  
# Overview
This is a customizable synthesizable 5G NR lower PHY written in Verilog intended to be used in a UE (user equipment). It can run on an [AntSDR e310]([https://www.analog.com/en/design-center/evaluation-hardware-and-software/evaluation-boards-kits/adalm-pluto.html](https://de.aliexpress.com/item/1005003181244737.html)), which has a Xilinx® Zynq Z-7020 with only 220 DSP slices and 85K logic cells, with a 5 MHz channel at 7.68 MSPS (512-FFT), 15.36 MSPS (1024-FFT) or 30.72 MSPS (2084-FFT) is also possible but not yet tested. In this 5 MHz configuration, 25 PRBs (physical ressource blocks) can be used. This will become a 5G NR standard compliant mode once 5G-NR RedCap will get standardized.
<br>
Cell search is limited to 1 frequency offset range. Within this frequency offset range, the PSS correlator works up to a CFO of about += 10 kHz.
Each PSS correlator detects one of the possible three different PSS sequences. If a general cell search for all 3 possible N_id_2's is needed, 3 PSS correlators need to be instanciated in parallel. If CFOs larger than the detection range of the PSS correlator are expected, the different CFO possibilities can be tried sequentially by configuring the receiver via its AXI-lite interface.
<br>
Interface to upper layers is currently implemented via AXI-lite for configuration and register access and AXI-MM for data transfer. Since the lower PHY split chosen in this design is identical with the O-RAN 7.2x option, it should be possible to implement a [eCPRI](http://www.cpri.info/downloads/eCPRI_v_2.0_2019_05_10c.pdf) interface which is [O-RAN FH](https://www.etsi.org/deliver/etsi_ts/103800_103899/103859/07.00.02_60/ts_103859v070002p.pdf) compatible for this core. However since O-RAN interfaces are mainly a thing for eNBs, this is not a priority for now.

Implemented so far:<br>
* Decimator [detailed description below](https://github.com/catkira/open5G_rx#decimator)
* PSS correlator [detailed description below](https://github.com/catkira/open5G_rx#pss-correlator)
* Peak detector [detailed description below](https://github.com/catkira/open5G_rx#peak-detector)
* PSS detector [detailed description below](https://github.com/catkira/open5G_rx#pss-detector)
* FFT demodulator [detailed description below](https://github.com/catkira/open5G_rx#fft-demodulator)
* SSS detector [detailed description below](https://github.com/catkira/open5G_rx#sss-detector)
* Frame sync [detailed description below](https://github.com/catkira/open5G_rx#frame-sync)
* Channel estimator [detailed description below](https://github.com/catkira/open5G_rx#channel-estimator)
* Ressource grid framer [detailed description below](https://github.com/catkira/open5G_rx#ressource-grid-framer)
* AXI-DMAC [detailed description below](https://github.com/catkira/open5G_rx#axi-dmac)

<br>
<b>Disclaimer:</b> This design is not intended for very high data rate applications, like 400 MHz massive MIMO channels or so. It is instead intended to use this as a basis for experiments with mobile data links that are '5G like' i.e. for UAV communication or HAM radio. The main goal of this design is to achieve a digital data link with fairly high data rates while using minimal ressources so that it can be used in portable battery powered devices. </b>
<br><br>

![Overview diagram](doc/overview.jpg)
(details such as timestamp logic are not shown in this diagram)

# Tests
Testbenches are written in Python using cocotb. For simulation both iverilog and Verilator are used. Iverilog is used for short tests whereas Verilator is used for tests with larger data throughput.
<br>
To install the necessary requirements for running the tests do (assuming You start in the dir where this repo is cloned):
```
  cd ..
  sudo apt install iverilog
  pip install -e requirements.txt
  git clone https://github.com/catkira/cocotb.git
  cd cocotb && pip install -e . && cd ..
  git clone https://github.com/verilator/verilator.git
  cd verilator
  git reset v5.006
  ./configure
  make -j$(nproc) && sudo make install
  cd ..
  cd open5G_rx
```
Then to run all tests do:
```
  pytest --workers $(nproc)
```
If You only want to run a simulation of the receiver do:
```
  pytest --workers $(nproc) tests/test_receiver.py
```
The following diagram shows the plots that test_receiver.py generates with 2300 Hz simulated CFO. The first plot shows the uncorrected IQ constellation plot for a PBCH packet which consists of 3 OFDM symbols. The second diagram shows the CFO corrected IQ constellation plot, red dots are from the first SSB, green dots are from the second SSB. The second SSB is received 20 ms after the first SSB and might contain a better CFO correction, because CFO correction improves itself iteratively up to a certain point. The third diagram shows the CFO and channel corrected IQ constellation of a PBCH packet. The red dots are from the first symbol, green dots from the second symbol and blue dots from the third symbol.
![Plots from test_receiver.py](doc/receiver_test_constellation_diagram.png)

# Decimator
The incoming sample rate to the SSB_sync module should be 3.84 MSPS. This sample rate is then internally decimated to 1.92 MSPS so that the PSS and SSS detection cores can run most efficiently.
The PBCH demodulation core needs 3.84 MSPS. Decimation is done by [this](https://github.com/catkira/CIC) CIC core which does not need any multiplications.

# PSS correlator
Without optimizations the PSS correlator would require 128 * 3 real multipliers, 3 real multipliers for each complex multiplication. The absolute value is calculated by an approximation and does not use any multipliers. This can be further optimized by taking into account that the PSS sequence in time domain is real valued. Therefore the PSS sequence in frequency domain is complex conjugate centrally symmetric. This can be used to reduce the required number of real multipliers to 128 * 2 + 2 as shown in [this](https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=8641097) paper. <br>
Further optimization can be achieved when taking into account that the sample rate for the SSB is only 3.84 MSPS (with 15 KHz SCS) and the PSS and SSB detection cores only need a sample rate of 1.92 MSPS. If the PSS correlator runs on a 122.88 Mhz clock, a single multiplier can be used to perform 64 multiplications at 1.92 MSPS. This feature is already implemented into the PSS correlator (PSS_correlator_mr.v) and can be adjusted by changing the MULT_REUSE parameter. <br>
For a sample rate of 1.92 MSPS and a clock rate of 122.88 MHz, the PSS correlator requires 2 * 2 real multipliers. <br><br>
The PSS correlator core supports variable widths for the data input (IN_DW), for the PSS coefficients (TAP_DW) and for the output (OUT_DW). The bit growth from input to output can be described as IN_DW / 2 + TAP_DW / 2 + 1 + ceil(log2(PSS_LEN)). If OUT_DW is not large enough to receive the whole bit growth, the output will be truncated so that only some LSBs get lost. However, in that case there will be unnecessary many ressources used, therefore it is recommended to configure the core in such a way that no truncation is needed. Since IN_DW and TAP_DW are widths for complex numbers, they have to be even numbers so that the real and imaginary part can have equal widths. <br>
A reasonable configuration would be: <br>
   IN_DW = 32 (signed I and Q) <br>
   TAP_DW = 32 (signed I and Q) <br>
   OUT_DW = 48 (unsigned) <br>
Calculation the growth gives: 16 + 16 + 1 + 7 = 40 <br>
This would allow DSP48E1 slices to be used, even for the last multipliers that are used to calculate the absolute value.
<br>
<b>TODO:</b> pipelining

# Peak detector
The peak detector takes the sum of the last WINDOW_LEN samples and compares it to the current sample. If the current sample is larger than the window sum times a DETECTION_FACTOR, then a peak is detected. DETECTION_FACTOR is currently hard coded to 16, so that the multiplication can be implemented as a shift operation. As result, this core only needs WINDOW_LEN additions and no multiplications. <br><br>
<b>TODO:</b> There is currently no pipelining implemented. For larger windows it is probably needed to break up the add operation into different stages.

# PSS detector
This core contains the decimator, PSS correlator, peak detector and CFO calculator. It also controls when the PSS correlator is active. The PSS correlator is deactived for 19.99 ms after the chosen SSB occured. 
<br>
There are usually multiple SSBs in one burst, which each SSBs coming from a different antenna. The UE is supposed to select the SSB with the strongest signal for synchronization. This design currently does not evaluate in HDL which SSB has the strongest signal, it just takes the first SSB which gets detected by the PSS correlator and peak detector. However, analysis which SSB is the best can be performed on the CPU. The CPU can then write the index of the strongest SSB (ibar_SSB) via AXI-lite to this core.

# FFT demodulator
The FFT demodulator uses [this](https://github.com/catkira/FFT) FFT core, it is configured to use dynamic block scaling. Since the core runs at 122.88 MHz while the sample rate it only 3.84 MSPS, overclocking can be used to reduce the number of required multipliers. Normally a FFT would need 3 real multipliers per stage, with overclocking this can be reduced to 1 multiplier per stage. SSS would only need a 128 point FFT, but a 256 point FFT is used anyway, so that it can also be used for PBCH demodulation. This results in 8 real multipliers required for the FFT. The FFT demodulator is synchronized to the start signal from the Peak detector. It then continuously performs FFTs. There are special tag signals for the start of the SSS and PBCH symbols. Zero carriers are removed from the output, so that each FFT outputs 240 subcarriers. The cyclic prefix advance is configurable. The ideal cyclic prefix advance to prevent ISI (inter symbol interference) is half a cyclic prefix length.

# SSS demodulator
The SSS detector currently operates in search mode, which means that it compares the received SSS sequence to all possible 335 SSS for the given N_id_1 which comes from the PSS detection.
The code is optimized to not use any multiplication and no large additions. This is achieved by doing every operation in a separate clock cycle. This means the core needs about 335 * 127 = 42545 cycles to finish the detection, assuming the system clock is 100 MHz, that would be 425 us.
The code is also memory optimized, by only storing the two m-sequences that are needed to construct all the possible SSS. It currently builds the stored m-sequences at startup using [this](https://github.com/catkira/LFSR) LFSR core. The code could be modified to have the m-sequences statically stored.

# Frame sync
This core keeps track of the current frame, subframe, slot and symbol number and controls the PSS detector. The 10 bit system frame number (SFN) whichs is contained in the BCH message needs to be sent to this core via AXI.
![Frame structure diagram](doc/frame_structure.jpg)
This core currently only supports 15 kHz SCS (subcarrier spacing) and the frame structure shown in the diagram above.
It also controls the PSS detector by sending it to sleep for 20 ms after a SSB was detected.
This core also sends the sync signals like SSB_start to the FFT_demod core. The FFT_demod core needs this timing information to generate timing information like SSS_valid and symbol_type information in its tuser output.
<br>
Frame sync outputs IQ samples in an AXI stream interface. The tuser field contains the following information {sfn, subframe_number, symbol_number, current_CP_len}. One packet has the length 512 + 18 or 512 + 20 depending on the CP length. tlast is used to signal end of packet.
<br>
<b>Important: after detection of the first SSB, sfn strats at 0. After decoding the MIB from the PBCH on the CPU, this core needs to receive the sfn of the SSB in order to output correct frame information in tuser. </b>

# Ressource Grid Framer
This core sends the ressource grid via DMA to the CPU. The core can be configured to start with a certain {Frame, Subframe, Symbol)-number. The core also monitors possible overflows, this should not happen if the DMA configuration of the CPU is correct. In case of an overflow, this core will stop forwarding symbols and set an overflow flag. The core always starts with the symbol where the PSS was detected. Starting with a defined symbol is necessary, because the AXI-DMA core does not transfer any meta information except the timestamp and block exponent with the payload. It is however considered to insert the {Frame, Subframe, Symbol)-number, this would only increase the data rate slightly but provide an extra level of robustness.
The block exponent is inserted at the beginning, it can be used for AGC (automatic gain control).
<br>
The data rate at the output of this core is roughly 100 frames/s * 10 subframes/frame * 14 symbols/subframe * 300 SC/symbol * 2 byte/SC = 8.4 MB/s (neglecting meta information) when using a BWP (bandwidth part) of 25 RBs like in a 5 MHz channel.
<br>
A non-continuous mode will possibly be added in the future. In the non-continuous mode it can be configured which symbols and subcarriers should be forwarded. This feature would need to scatter-gather functionality in order two forward two different blocks that are close to each other on the time axis.

# AXI-DMAC
This is a core from Analog Devices that can be found [here](https://github.com/analogdevicesinc/hdl/tree/master/library/axi_dmac). It is used with source AXI-stream interface, because this allows the RGS core to see when an overflow would happen (the source fifo interface of the axi-dmac core does not have a ready output). The advantage of using this core is that there is already a DMA kernel driver, a kernel iio driver and also client libraries (libiio). The kernel DMA driver, axi-dmac.c, provides an interface to the linux kernel DMA engine. The kernel iio driver, provides an interface to the user-space via ioctl() calls. Libiio is a user-space wrapper around the iio interface that provides a convenient API for creating DMA buffers, and enqueuing/dequeuing DMA transfers.
<br>
The CPU part of the phy allocates blocks that have the size of a single frame, this is 10 subframes/frame * 14 symbols/subframe * (300 + 1) SCs/symbol * 2 bytes/SC = 82.28 kB/frame (including timestamp for every symbol) for a 5 MHz channel.
<br>
Tricky situation: When the FPGA loses synchronizations, it signals this via an IRQ from frame_sync to the CPU. The CPU then aborts all pending DMA transfers and after that initiated another sync procedure by writing via AXI-lite to the frame_sync core. Pending transfers can be aborted with iio_buffer_set_enabled(...) when using libiio, or by writing to the "enable" device attribute when using the iio sysfs interface directly. 

# Channel estimator
The channel estimator currently only corrects the phase angles of PBCH symbols, this is enough to do the QPSK demodulation. It also detects the PBCH DMRS (DeModulation Reference Sequence) by comparing the incoming pilots with the 8 possible ibar_SSB configurations. The 5G standard recommends to blind decode the received PBCH for all 8 possible ibar_SSBs, this would be a more robust solution. This channel estimator will be obsolete once the actual upper phy is implemented on a CPU. Until then, it is useful for testing.
<br>
TODO: The detected ibar_SSB can be verified by setting a threshold on the correlation of the PBCH DMRS comparison. If the result is below the threshold the PSS detector should go back into search mode and search for another SSB.
<br>
The detected ibar_SSB is send to the frame_sync core which uses this signal to align itself to the right subframe number.
![Channel estimator diagram](doc/channel_estimator.jpg)
