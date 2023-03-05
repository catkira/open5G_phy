import numpy as np
import scipy
import os
import pytest
import logging
import matplotlib.pyplot as plt
import os

import cocotb
import cocotb_test.simulator
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotbext.axi import AxiLiteBus, AxiLiteMaster

import py3gpp
import sigmf

CLK_PERIOD_NS = 8
CLK_PERIOD_S = CLK_PERIOD_NS * 0.000000001
tests_dir = os.path.abspath(os.path.dirname(__file__))
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', 'hdl'))

def _twos_comp(val, bits):
    """compute the 2's complement of int value val"""
    if (val & (1 << (bits - 1))) != 0:
        val = val - (1 << bits)
    return int(val)

class TB(object):
    def __init__(self, dut):
        self.dut = dut
        self.IN_DW = int(dut.IN_DW.value)
        self.OUT_DW = int(dut.OUT_DW.value)
        self.TAP_DW = int(dut.TAP_DW.value)
        self.PSS_LEN = int(dut.PSS_LEN.value)
        self.ALGO = int(dut.ALGO.value)
        self.WINDOW_LEN = int(dut.WINDOW_LEN.value)
        self.HALF_CP_ADVANCE = int(dut.HALF_CP_ADVANCE.value)
        self.LLR_DW = int(dut.LLR_DW.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())
        cocotb.start_soon(Clock(self.dut.sample_clk_i, CLK_PERIOD_NS, units='ns').start())  # TODO make sample_clk_i 3.84 MHz and clk_i 122.88 MHz

    async def cycle_reset(self):
        self.dut.s_axis_in_tvalid.value = 0
        self.dut.reset_ni.setimmediatevalue(1)
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 0
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 1
        await RisingEdge(self.dut.clk_i)

@cocotb.test()
async def simple_test(dut):
    tb = TB(dut)
    CFO = int(os.getenv('CFO'))
    handle = sigmf.sigmffile.fromfile('../../tests/30720KSPS_dl_signal.sigmf-data')
    waveform = handle.read_samples()
    fs = 30720000
    print(f'CFO = {CFO} Hz')
    waveform *= np.exp(np.arange(len(waveform)) * 1j * 2 * np.pi * CFO / fs)
    waveform = scipy.signal.decimate(waveform, 8, ftype='fir')  # decimate to 3.840 MSPS
    fs = 3.84e6
    waveform /= max(np.abs(waveform.real.max()), np.abs(waveform.imag.max()))
    MAX_AMPLITUDE = (2 ** (tb.IN_DW // 2 - 1) - 1)
    waveform *= MAX_AMPLITUDE * 0.8  # need this 0.8 because rounding errors caused overflows, nasty bug!
    assert np.abs(waveform.real).max().astype(int) <= MAX_AMPLITUDE, "Error: input data overflow!"
    assert np.abs(waveform.imag).max().astype(int) <= MAX_AMPLITUDE, "Error: input data overflow!"
    waveform = waveform.real.astype(int) + 1j * waveform.imag.astype(int)

    await tb.cycle_reset()

    rx_counter = 0
    in_counter = 0
    received = []
    received_fft = []
    received_fft_demod = []
    rx_ADC_data = []
    received_PBCH = []
    received_SSS = []
    corrected_PBCH = []
    received_PBCH_LLR = []
    fft_started = False
    CP2_LEN = 18
    HALF_CP_ADVANCE = tb.HALF_CP_ADVANCE
    FFT_SIZE = 256
    SSS_LEN = 127
    SSS_START = 64
    DETECTOR_LATENCY = 27
    FFT_OUT_DW = 32
    SYMBOL_LEN = 240
    max_tx = int(0.045 * fs) # simulate 45ms tx data
    while in_counter < max_tx + 10000:
        await RisingEdge(dut.clk_i)
        if in_counter < max_tx:
            data = (((int(waveform[in_counter].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
                + ((int(waveform[in_counter].real)) & ((2 ** (tb.IN_DW // 2)) - 1))) & ((2 ** tb.IN_DW) - 1)
            dut.s_axis_in_tdata.value = data
            dut.s_axis_in_tvalid.value = 1
        else:
            dut.s_axis_in_tvalid.value = 0

        in_counter += 1

        received.append(dut.peak_detected_debug_o.value.integer)
        rx_counter += 1

        if dut.peak_detected_debug_o.value.integer == 1:
            print(f'peak pos = {in_counter}')

        if dut.peak_detected_debug_o.value.integer == 1 or len(rx_ADC_data) > 0:
            rx_ADC_data.append(waveform[in_counter - DETECTOR_LATENCY])

        # if dut.m_axis_SSS_tvalid.value.integer == 1:
        #     print(f'detected N_id_1 = {dut.m_axis_SSS_tdata.value.integer}')

        if dut.m_axis_llr_out_tvalid.value == 1 and dut.m_axis_llr_out_tuser.value == 1:
            received_PBCH_LLR.append(_twos_comp(dut.m_axis_llr_out_tdata.value.integer & (2 ** (tb.LLR_DW // 2) - 1), tb.LLR_DW // 2))

        if dut.m_axis_cest_out_tvalid.value == 1 and dut.m_axis_cest_out_tuser.value == 1:
            corrected_PBCH.append(_twos_comp(dut.m_axis_cest_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_cest_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

        if dut.PBCH_valid_o.value.integer == 1:
            # print(f"rx PBCH[{len(received_PBCH):3d}] re = {dut.m_axis_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1):4x} " \
            #     "im = {(dut.m_axis_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1):4x}")
            received_PBCH.append(_twos_comp(dut.m_axis_demod_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_demod_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

        if dut.SSS_valid_o.value.integer == 1:
            # print(f"rx SSS[{len(received_SSS):3d}]")
            received_SSS.append(_twos_comp(dut.m_axis_demod_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_demod_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

        if dut.m_axis_demod_out_tvalid.value.binstr == '1':
            # print(f'{rx_counter}: fft_demod {dut.m_axis_out_tdata.value}')
            received_fft_demod.append(_twos_comp(dut.m_axis_demod_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_demod_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

        if fft_started:
            # print(f'{rx_counter}: fft_debug {dut.fft_result_debug_o.value}')
            received_fft.append(_twos_comp(dut.fft_result_debug_o.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.fft_result_debug_o.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

    print(f'received {len(corrected_PBCH)} PBCH IQ samples')
    print(f'received {len(received_PBCH_LLR)} PBCH LLRs samples')
    assert len(received_SSS) == 3 * SSS_LEN
    assert len(corrected_PBCH) == 432 * 2, print('received PBCH does not have correct length!')
    assert len(received_PBCH_LLR) == 432 * 4, print('received PBCH LLRs do not have correct length!')

    axi_master = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "s_axi_if"), dut.clk_i)

    addr = 0
    data = await axi_master.read_dword(4 * addr)
    data = int(data)
    assert data == 0x00010069

    addr = 7
    data = await axi_master.read_dword(4 * addr)
    data = int(data)
    print(f'axis_axil_fifo contains {data} elements')

    CP_ADVANCE = 9 if HALF_CP_ADVANCE else 18
    ideal_SSS_sym = np.fft.fftshift(np.fft.fft(rx_ADC_data[CP2_LEN + FFT_SIZE + CP_ADVANCE:][:FFT_SIZE]))
    ideal_SSS_sym *= np.exp(1j * ( 2 * np.pi * (CP2_LEN - CP_ADVANCE) / FFT_SIZE * np.arange(FFT_SIZE) + np.pi * (CP2_LEN - CP_ADVANCE)))
    ideal_SSS = ideal_SSS_sym[SSS_START:][:SSS_LEN]
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        ax = plt.subplot(2, 4, 1)
        ax.set_title('model whole symbol')
        ax.plot(np.abs(ideal_SSS_sym))
        ax = plt.subplot(2, 4, 2)
        ax.set_title('model used SCs abs')
        ax.plot(np.abs(ideal_SSS), 'r-')
        ax = plt.subplot(2, 4, 3)
        ax.set_title('model used SCs I/Q')
        ax.plot(np.real(ideal_SSS), 'r-')
        ax = ax.twinx()
        ax.plot(np.imag(ideal_SSS), 'b-')
        ax = plt.subplot(2, 4, 4)
        ax.set_title('model used SCs constellation')
        ax.plot(np.real(ideal_SSS), np.imag(ideal_SSS), 'r.')

        ax = plt.subplot(2, 4, 6)
        ax.set_title('hdl used SCs abs')
        ax.plot(np.abs(received_SSS[:SSS_LEN]), 'r-')
        ax.plot(np.abs(received_SSS[SSS_LEN:][:SSS_LEN]), 'b-')
        ax = plt.subplot(2, 4, 7)
        ax.set_title('hdl used SCs I/Q')
        ax.plot(np.real(received_SSS[:SSS_LEN]), 'r-')
        ax = ax.twinx()
        ax.plot(np.imag(received_SSS[:SSS_LEN]), 'b-')
        ax = plt.subplot(2, 4, 8)
        ax.set_title('hdl used SCs I/Q constellation')
        ax.plot(np.real(received_SSS[:SSS_LEN]), np.imag(received_SSS[:SSS_LEN]), 'r.')
        ax.plot(np.real(received_SSS[SSS_LEN:][:SSS_LEN]), np.imag(received_SSS[:SSS_LEN]), 'b.')
        
        # ax = plt.subplot(2, 4, 8)
        # ax.plot(np.real(corrected_PBCH[:180]), np.imag(corrected_PBCH[:180]), 'r.')
        # ax.plot(np.real(corrected_PBCH[180:][:72]), np.imag(corrected_PBCH[180:][:72]), 'g.')
        # ax.plot(np.real(corrected_PBCH[180 + 72:]), np.imag(corrected_PBCH[180 + 72:]), 'b.')
        plt.show()

    received_PBCH_ideal = np.fft.fftshift(np.fft.fft(rx_ADC_data[CP_ADVANCE:][:FFT_SIZE]))
    received_PBCH_ideal *= np.exp(1j * ( 2 * np.pi * (CP2_LEN - CP_ADVANCE) / FFT_SIZE * np.arange(FFT_SIZE) + np.pi * (CP2_LEN - CP_ADVANCE)))
    received_PBCH_ideal = received_PBCH_ideal[8:][:SYMBOL_LEN]
    received_PBCH_ideal = (received_PBCH_ideal.real.astype(int) + 1j * received_PBCH_ideal.imag.astype(int))
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, axs = plt.subplots(1, 3, figsize=(10, 5))
        axs[0].set_title('CFO corrected SSS')
        axs[0].plot(np.real(received_SSS)[:SSS_LEN], np.imag(received_SSS)[:SSS_LEN], 'r.')
        axs[0].plot(np.real(received_SSS)[SSS_LEN:][:SSS_LEN], np.imag(received_SSS)[SSS_LEN:][:SSS_LEN], 'b.')

        axs[1].set_title('CFO corrected PBCH')
        axs[1].plot(np.real(received_PBCH[:SYMBOL_LEN]), np.imag(received_PBCH[:SYMBOL_LEN]), 'r.')
        axs[1].plot(np.real(received_PBCH[SYMBOL_LEN:][:SYMBOL_LEN]), np.imag(received_PBCH[SYMBOL_LEN:][:SYMBOL_LEN]), 'g.')
        axs[1].plot(np.real(received_PBCH[2*SYMBOL_LEN:][:SYMBOL_LEN]), np.imag(received_PBCH[2*SYMBOL_LEN:][:SYMBOL_LEN]), 'b.')
        #axs[2].plot(np.real(received_PBCH_ideal), np.imag(received_PBCH_ideal), 'y.')

        axs[2].set_title('CFO and channel corrected PBCH')
        axs[2].plot(np.real(corrected_PBCH[:180]), np.imag(corrected_PBCH[:180]), 'r.')
        axs[2].plot(np.real(corrected_PBCH[180:][:72]), np.imag(corrected_PBCH[180:][:72]), 'g.')
        axs[2].plot(np.real(corrected_PBCH[180 + 72:][:180]), np.imag(corrected_PBCH[180 + 72:][:180]), 'b.')
        plt.show()

    peak_pos = np.argmax(received)
    print(f'highest peak at {peak_pos}')

    NFFT = 8
    scaling_factor = 2**(tb.IN_DW + NFFT - tb.OUT_DW) # FFT core is in truncation mode
    ideal_SSS = ideal_SSS.real / scaling_factor + 1j * ideal_SSS.imag / scaling_factor

    assert peak_pos == 850
    corr = np.zeros(335)
    for i in range(335):
        sss = py3gpp.nrSSS(i)
        corr[i] = np.abs(np.vdot(sss, received_SSS[:SSS_LEN]))
    detected_NID = np.argmax(corr)
    assert detected_NID == 209

    # try to decode PBCH
    ibar_SSB = 0 # TODO grab this from hdl
    nVar = 1
    corrected_PBCH = np.array(corrected_PBCH)[:432]
    for mode in ['hard', 'soft', 'hdl']:
        print(f'demodulation mode: {mode}')
        if mode == 'hdl':
            pbchBits = np.array(received_PBCH_LLR)[:432 * 2]
        else:
            pbchBits = py3gpp.nrSymbolDemodulate(corrected_PBCH, 'QPSK', nVar, mode)

        E = 864
        v = ibar_SSB
        scrambling_seq = py3gpp.nrPBCHPRBS(detected_NID, v, E)
        scrambling_seq_bpsk = (-1) * scrambling_seq * 2 + 1
        pbchBits_descrambled = pbchBits * scrambling_seq_bpsk

        A = 32
        P = 24
        K = A+P
        N = 512 # calculated according to Section 5.3.1 of 3GPP TS 38.212
        decIn = py3gpp.nrRateRecoverPolar(pbchBits_descrambled, K, N, False, discardRepetition=False)
        decoded = py3gpp.nrPolarDecode(decIn, K, 0, 0)

        # check CRC
        _, crc_result = py3gpp.nrCRCDecode(decoded, '24C')
        if crc_result == 0:
            print("nrPolarDecode: PBCH CRC ok")
        else:
            print("nrPolarDecode: PBCH CRC failed")
        assert crc_result == 0

@pytest.mark.parametrize("ALGO", [0])
@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("WINDOW_LEN", [8])
@pytest.mark.parametrize("CFO", [0, 1200])
@pytest.mark.parametrize("HALF_CP_ADVANCE", [0, 1])
@pytest.mark.parametrize("USE_TAP_FILE", [1])
@pytest.mark.parametrize("LLR_DW", [16])
def test(IN_DW, OUT_DW, TAP_DW, ALGO, WINDOW_LEN, CFO, HALF_CP_ADVANCE, USE_TAP_FILE, LLR_DW):
    dut = 'receiver'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    unisim_dir = os.path.join(rtl_dir, '../submodules/FFT/submodules/XilinxUnisimLibrary/verilog/src/unisims')
    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'atan.sv'),
        os.path.join(rtl_dir, 'atan2.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'AXIS_FIFO.sv'),
        os.path.join(rtl_dir, 'frame_sync.sv'),
        os.path.join(rtl_dir, 'channel_estimator.sv'),
        os.path.join(rtl_dir, 'demap.sv'),
        os.path.join(rtl_dir, 'PSS_detector_regmap.sv'),
        os.path.join(rtl_dir, 'AXI_lite_interface.sv'),
        os.path.join(rtl_dir, 'PSS_detector.sv'),
        os.path.join(rtl_dir, 'CFO_calc.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv'),
        os.path.join(rtl_dir, 'SSS_detector.sv'),
        os.path.join(rtl_dir, 'LFSR/LFSR.sv'),
        os.path.join(rtl_dir, 'FFT_demod.sv'),
        os.path.join(rtl_dir, 'axis_axil_fifo.sv'),
        os.path.join(rtl_dir, 'DDS', 'dds.sv'),
        os.path.join(rtl_dir, 'complex_multiplier', 'complex_multiplier.v'),
        os.path.join(rtl_dir, 'CIC/cic_d.sv'),
        os.path.join(rtl_dir, 'CIC/comb.sv'),
        os.path.join(rtl_dir, 'CIC/downsampler.sv'),
        os.path.join(rtl_dir, 'CIC/integrator.sv'),
        os.path.join(rtl_dir, 'FFT/fft/fft.v'),
        os.path.join(rtl_dir, 'FFT/fft/int_dif2_fly.v'),
        os.path.join(rtl_dir, 'FFT/fft/int_fftNk.v'),
        os.path.join(rtl_dir, 'FFT/math/int_addsub_dsp48.v'),
        os.path.join(rtl_dir, 'FFT/math/cmult/int_cmult_dsp48.v'),
        os.path.join(rtl_dir, 'FFT/math/cmult/int_cmult18x25_dsp48.v'),
        os.path.join(rtl_dir, 'FFT/twiddle/rom_twiddle_int.v'),
        os.path.join(rtl_dir, 'FFT/delay/int_align_fft.v'),
        os.path.join(rtl_dir, 'FFT/delay/int_delay_line.v'),
        os.path.join(rtl_dir, 'FFT/buffers/inbuf_half_path.v'),
        os.path.join(rtl_dir, 'FFT/buffers/outbuf_half_path.v'),
        os.path.join(rtl_dir, 'FFT/buffers/int_bitrev_order.v')
    ]
    if os.environ.get('SIM') != 'verilator':
        verilog_sources.append(os.path.join(rtl_dir, '../submodules/FFT/submodules/XilinxUnisimLibrary/verilog/src/glbl.v'))

    includes = [
        os.path.join(rtl_dir, 'CIC'),
        os.path.join(rtl_dir, 'fft-core')
    ]

    PSS_LEN = 128
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters['OUT_DW'] = OUT_DW
    parameters['TAP_DW'] = TAP_DW
    parameters['PSS_LEN'] = PSS_LEN
    parameters['ALGO'] = ALGO
    parameters['WINDOW_LEN'] = WINDOW_LEN
    parameters['HALF_CP_ADVANCE'] = HALF_CP_ADVANCE
    parameters['USE_TAP_FILE'] = USE_TAP_FILE
    parameters['LLR_DW'] = LLR_DW
    os.environ['CFO'] = str(CFO)
    parameters_dirname = parameters.copy()
    parameters_dirname['CFO'] = CFO
    folder = 'receiver_' + '_'.join(('{}={}'.format(*i) for i in parameters_dirname.items()))
    sim_build='sim_build/' + folder

    for i in range(3):
        # imaginary part is in upper 16 Bit
        PSS = np.zeros(PSS_LEN, 'complex')
        PSS[0:-1] = py3gpp.nrPSS(i)
        taps = np.fft.ifft(np.fft.fftshift(PSS))
        taps /= max(taps.real.max(), taps.imag.max())
        taps *= 2 ** (TAP_DW // 2 - 1)
        parameters[f'PSS_LOCAL_{i}'] = 0
        PSS_taps = np.empty(PSS_LEN, int)
        for k in range(len(taps)):
            if not USE_TAP_FILE:
                parameters[f'PSS_LOCAL_{i}'] += ((int(np.round(np.imag(taps[k]))) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * k + TAP_DW // 2)) \
                                        + ((int(np.round(np.real(taps[k]))) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * k))
            PSS_taps[k] = ((int(np.imag(taps[k])) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW // 2)) \
                                    + (int(np.real(taps[k])) & (2 ** (TAP_DW // 2) - 1))
        if USE_TAP_FILE:
            parameters[f'TAP_FILE_{i}'] = f'\"../{folder}_PSS_{i}_taps.txt\"'
            os.environ[f'TAP_FILE_{i}'] = f'../{folder}_PSS_{i}_taps.txt'
            os.makedirs("sim_build", exist_ok=True)
            np.savetxt(sim_build + f'_PSS_{i}_taps.txt', PSS_taps, fmt = '%x', delimiter = ' ')
    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}
    
    compile_args = []
    if os.environ.get('SIM') == 'verilator':
        compile_args = ['--build-jobs', '16', '--no-timing', '-Wno-fatal', '-Wno-PINMISSING','-y', tests_dir + '/../submodules/verilator-unisims']
    else:
        compile_args = ['-sglbl', '-y' + unisim_dir]
    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        includes=includes,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env,
        testcase='simple_test',
        force_compile=True,
        waves=True,
        defines = ['LUT_PATH=\"../../tests\"'],
        compile_args = compile_args
    )

if __name__ == '__main__':
    os.environ['PLOTS'] = '1'
    os.environ['SIM'] = 'verilator'
    test(IN_DW = 32, OUT_DW = 32, TAP_DW = 32, ALGO = 0, WINDOW_LEN = 8, CFO=2400, HALF_CP_ADVANCE = 1, USE_TAP_FILE = 1, LLR_DW = 16)
