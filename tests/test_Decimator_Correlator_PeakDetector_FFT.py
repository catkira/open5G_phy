import numpy as np
import scipy
import os
import pytest
import logging
import matplotlib.pyplot as plt
import os
import importlib.util

import cocotb
import cocotb_test.simulator
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

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
        self.NFFT = int(dut.NFFT.value)
        self.MULT_REUSE = int(dut.MULT_REUSE.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())

    async def cycle_reset(self):
        self.dut.s_axis_in_tvalid.value = 0
        self.dut.reset_ni.setimmediatevalue(1)
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 0
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 1
        await RisingEdge(self.dut.clk_i)

    def fft_dbs(self, fft_signal, width):
        max_im = np.abs(fft_signal.imag).max()
        max_re = np.abs(fft_signal.real).max()
        max_abs_val = max(max_im, max_re)
        shift_factor = width - np.ceil(np.log2(max_abs_val)) - 1
        return fft_signal * (2 ** shift_factor)

@cocotb.test()
async def simple_test(dut):
    tb = TB(dut)
    FILE = '../../tests/' + os.environ['TEST_FILE'] + '.sigmf-data'
    handle = sigmf.sigmffile.fromfile(FILE)
    waveform = handle.read_samples()
    fs = handle.get_global_field(sigmf.SigMFFile.SAMPLE_RATE_KEY)

    if os.environ['TEST_FILE'] == '30720KSPS_dl_signal':
        expected_N_id_1 = 69
        expected_N_id_2 = 2
        waveform /= max(waveform.real.max(), waveform.imag.max())
        dec_factor = int((2048 * fs // 30720000) // (2 ** tb.NFFT))
        assert dec_factor != 0, f'NFFT = {tb.NFFT} and fs = {fs} is not possible!'
        print(f'test_file = {FILE} with {len(waveform)} samples')
        print(f'sample_rate = {fs}, decimation_factor = {dec_factor}')
        if dec_factor > 1:
            fs = fs // dec_factor
            waveform = scipy.signal.decimate(waveform, dec_factor, ftype='fir')  # decimate to 3.840 MSPS (if NFFT = 8)
        waveform /= max(waveform.real.max(), waveform.imag.max())
        waveform *= (2 ** (tb.IN_DW // 2 - 1) - 1)
        waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)
    elif os.environ['TEST_FILE'] == '772850KHz_3840KSPS_low_gain':
        expected_N_id_1 = 291
        expected_N_id_2 = 0
        delta_f = -4e3
        waveform *= 2**19 # exported files from sdrangel are scaled like this
        waveform = waveform * np.exp(-1j*(2*np.pi*delta_f/fs*np.arange(waveform.shape[0])))
        # waveform /= max(waveform.real.max(), waveform.imag.max())
        # waveform *= (2 ** (tb.IN_DW // 2 - 1) - 1)
        waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)
    else:
        file_string = os.environ['TEST_FILE']
        assert False, f'test file {file_string} is not supported'


    await tb.cycle_reset()

    rx_counter = 0
    clk_cnt = 0
    received = []
    rx_ADC_data = []
    received_PBCH = []
    received_SSS = []

    NFFT = tb.NFFT
    FFT_LEN = 2 ** NFFT
    MAX_CLK_CNT = 3000 * FFT_LEN // 256
    CP_LEN = 18 * FFT_LEN // 256
    HALF_CP_ADVANCE = tb.HALF_CP_ADVANCE
    FFT_OUT_DW = 32

    SSS_LEN = 127
    SSS_START = FFT_LEN // 2 - (SSS_LEN + 1) // 2
    PBCH_SYMBOL_LEN = 240
    PBCH_START = FFT_LEN // 2 - (PBCH_SYMBOL_LEN + 1) // 2
    PSS_IDLE_CLKS = int(fs // 1920000)
    print(f'FREE_CYCLES = {PSS_IDLE_CLKS}')
    EXTRA_IDLE_CLKS = 0 if PSS_IDLE_CLKS >= tb.MULT_REUSE else tb.MULT_REUSE // PSS_IDLE_CLKS - 1 # insert additional valid 0 cycles if needed
    print(f'additional idle cycles per sample: {EXTRA_IDLE_CLKS}')
    clk_div = 0
    MAX_CLK_CNT = 10000 * FFT_LEN // 256 * (1 + EXTRA_IDLE_CLKS)
    peaks = []

    tx_cnt = 0
    sample_cnt = 0
    while (len(received_SSS) < SSS_LEN) and (clk_cnt < MAX_CLK_CNT):
        await RisingEdge(dut.clk_i)
        if (clk_div == 0 or EXTRA_IDLE_CLKS == 0):
            data = (((int(waveform[tx_cnt].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
                + ((int(waveform[tx_cnt].real)) & ((2 ** (tb.IN_DW // 2)) - 1))) & ((2 ** tb.IN_DW) - 1)
            dut.s_axis_in_tdata.value = data
            dut.s_axis_in_tvalid.value = 1
            clk_div += 1
            tx_cnt += 1
        else:
            dut.s_axis_in_tvalid.value = 0
            if clk_div == EXTRA_IDLE_CLKS:
                clk_div = 0
            else:
                clk_div += 1

        #print(f"data[{in_counter}] = {(int(waveform[in_counter].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)):4x} {(int(waveform[in_counter].real)  & ((2 ** (tb.IN_DW // 2)) - 1)):4x}")
        clk_cnt += 1

        # sample_cnt = clk_cnt // SAMPLE_CLK_DECIMATION if SAMPLE_CLK_DECIMATION > 1 else clk_cnt
        received.append(dut.peak_detected_debug_o.value.integer)
        rx_counter += 1

        if dut.peak_detected_debug_o.value.integer == 1:
            peaks.append(sample_cnt)
            print(f'peak pos = {sample_cnt}')
        sample_cnt += dut.m_axis_PSS_out_tvalid.value.integer

        if dut.PBCH_valid_o.value.integer == 1:
            # print(f"rx PBCH[{len(received_PBCH):3d}] re = {dut.m_axis_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1):4x} " \
            #     "im = {(dut.m_axis_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1):4x}")
            received_PBCH.append(_twos_comp(dut.m_axis_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

        if dut.SSS_valid_o.value.integer == 1:
            # print(f"rx SSS[{len(received_SSS):3d}]")
            received_SSS.append(_twos_comp(dut.m_axis_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

    assert clk_cnt < MAX_CLK_CNT, "timeout, did not receive enough data"
    assert len(received_SSS) == SSS_LEN

    print(f'first peak at = {peaks[0]}')
    rx_ADC_data = waveform[peaks[0] + CP_LEN + FFT_LEN - 1:]
    CP_ADVANCE = CP_LEN // 2 if HALF_CP_ADVANCE else CP_LEN
    ideal_SSS_sym = np.fft.fftshift(np.fft.fft(rx_ADC_data[CP_LEN + FFT_LEN + CP_ADVANCE:][:FFT_LEN]))
    scaling_factor = 2 ** (tb.IN_DW / 2 + NFFT - FFT_OUT_DW / 2) # FFT core is in truncation mode
    ideal_SSS_sym = ideal_SSS_sym.real / scaling_factor + 1j * ideal_SSS_sym.imag / scaling_factor
    ideal_SSS_sym = tb.fft_dbs(ideal_SSS_sym, FFT_OUT_DW / 2)
    ideal_SSS_sym *= np.exp(1j * (2 * np.pi * (CP_LEN - CP_ADVANCE) / FFT_LEN * np.arange(FFT_LEN) + np.pi * (CP_LEN - CP_ADVANCE)))
    ideal_SSS = ideal_SSS_sym[SSS_START:][:SSS_LEN]
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        ax = plt.subplot(4, 2, 1)
        ax.plot(np.abs(ideal_SSS_sym))
        ax = plt.subplot(4, 2, 2)
        ax.set_title('model')
        ax.plot(np.abs(ideal_SSS))
        ax = plt.subplot(4, 2, 3)
        ax.plot(np.real(ideal_SSS), 'r-')
        ax = ax.twinx()
        ax.plot(np.imag(ideal_SSS), 'b-')
        ax = plt.subplot(4, 2, 4)
        ax.plot(np.real(ideal_SSS), np.imag(ideal_SSS), '.')

        ax = plt.subplot(4, 2, 5)
        ax = plt.subplot(4, 2, 6)
        ax.plot(np.abs(received_SSS))
        ax.set_title('hdl')
        ax = plt.subplot(4, 2, 7)
        ax.plot(np.real(received_SSS), 'r-')
        ax = ax.twinx()
        ax.plot(np.imag(received_SSS), 'b-')
        ax = plt.subplot(4, 2, 8)
        ax.plot(np.real(received_SSS), np.imag(received_SSS), '.')
        plt.show()

    #received_PBCH= received_PBCH[9:][:FFT_SIZE-8*2 - 1]
    received_PBCH_ideal = np.fft.fftshift(np.fft.fft(rx_ADC_data[CP_ADVANCE:][:FFT_LEN]))
    received_PBCH_ideal *= np.exp(1j * ( 2 * np.pi * (CP_LEN - CP_ADVANCE) / FFT_LEN * np.arange(FFT_LEN) + np.pi * (CP_LEN - CP_ADVANCE)))
    received_PBCH_ideal = received_PBCH_ideal[PBCH_START:][:PBCH_SYMBOL_LEN]
    received_PBCH_ideal = (received_PBCH_ideal.real.astype(int) + 1j * received_PBCH_ideal.imag.astype(int))
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, axs = plt.subplots(2, 2, figsize=(10, 10))
        axs[0, 0].plot(np.real(received_SSS), np.imag(received_SSS), '.')
        axs[0, 1].plot(np.real(ideal_SSS), np.imag(ideal_SSS), '.')
        axs[0, 0].set_title('hdl SSS')
        axs[0, 1].set_title('model SSS')
        axs[1, 0].plot(np.real(received_PBCH[:PBCH_SYMBOL_LEN]), np.imag(received_PBCH[:PBCH_SYMBOL_LEN]), '.')
        axs[1, 1].plot(np.real(received_PBCH_ideal), np.imag(received_PBCH_ideal), '.')
        axs[1, 1].set_title('hdl PBCH')
        axs[1, 1].set_title('model PBCH')
        plt.show()

    # peak_pos = np.argmax(received[:np.round(fs * 0.02).astype(int)]) # max peak within first 20 ms
    peak_pos = peaks[0]
    print(f'first peak at {peak_pos}')

    assert len(received_SSS) == 127

    error_signal = received_SSS - ideal_SSS
    if tb.HALF_CP_ADVANCE:
        if os.environ['TEST_FILE'] == '30720KSPS_dl_signal':
            assert max(np.abs(error_signal)) < max(np.abs(received_SSS)) * 0.01
        else:
            assert max(np.abs(error_signal)) < max(np.abs(received_SSS)) * 0.1
    else:
        if os.environ['TEST_FILE'] == '30720KSPS_dl_signal':
            assert max(np.abs(error_signal)) < max(np.abs(received_SSS)) * 0.04
        else:
            assert max(np.abs(error_signal)) < max(np.abs(received_SSS)) * 0.4

    # this test is not ideal, because the maximum peak could be any of the 4 SSBs within one burst
    if os.environ['TEST_FILE'] == '30720KSPS_dl_signal':
        if NFFT == 8:
            assert peak_pos == 551
        elif NFFT == 9:
            assert peak_pos == 1101
        elif NFFT == 10:
            assert peak_pos == 2201
        elif NFFT == 11:
            assert peak_pos == 4401
    else:
        if NFFT == 8:
            assert peak_pos == 2113

    corr = np.zeros(335)
    for i in range(335):
        sss = py3gpp.nrSSS(i*3 + expected_N_id_2)
        corr[i] = np.abs(np.vdot(sss, ideal_SSS))

    detected_N_id_1 = np.argmax(corr)
    assert detected_N_id_1 == expected_N_id_1


# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("ALGO", [0, 1])
@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("WINDOW_LEN", [8])
@pytest.mark.parametrize("HALF_CP_ADVANCE", [0, 1])
@pytest.mark.parametrize("NFFT", [8, 9, 10])
@pytest.mark.parametrize("USE_TAP_FILE", [1])
@pytest.mark.parametrize("MULT_REUSE", [0, 1, 4, 32])
@pytest.mark.parametrize("INITIAL_DETECTION_SHIFT", [4])
def test(IN_DW, OUT_DW, TAP_DW, ALGO, WINDOW_LEN, HALF_CP_ADVANCE, NFFT, USE_TAP_FILE, MULT_REUSE, INITIAL_DETECTION_SHIFT, FILE = '30720KSPS_dl_signal'):
    dut = 'Decimator_Correlator_PeakDetector_FFT'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    unisim_dir = os.path.join(rtl_dir, '../submodules/FFT/submodules/XilinxUnisimLibrary/verilog/src/unisims')
    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'atan.sv'),
        os.path.join(rtl_dir, 'atan2.sv'),
        os.path.join(rtl_dir, 'PSS_detector_regmap.sv'),
        os.path.join(rtl_dir, 'AXI_lite_interface.sv'),
        os.path.join(rtl_dir, 'PSS_detector.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv'),
        os.path.join(rtl_dir, 'PSS_correlator_mr.sv'),
        os.path.join(rtl_dir, 'CFO_calc.sv'),
        os.path.join(rtl_dir, 'AXIS_FIFO.sv'),
        os.path.join(rtl_dir, 'FFT_demod.sv'),
        os.path.join(rtl_dir, 'frame_sync.sv'),
        os.path.join(rtl_dir, 'complex_multiplier/complex_multiplier.sv'),
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
        os.path.join(rtl_dir, 'FFT/buffers/int_bitrev_order.v'),
        os.path.join(rtl_dir, 'FFT/buffers/dynamic_block_scaling.v'),
        os.path.join(rtl_dir, 'BWP_extractor.sv')
    ]
    if os.environ.get('SIM') != 'verilator':
        verilog_sources.append(os.path.join(rtl_dir, '../submodules/FFT/submodules/XilinxUnisimLibrary/verilog/src/glbl.v'))
    includes = [
        os.path.join(rtl_dir, 'CIC'),
        os.path.join(rtl_dir, 'fft-core')
    ]

    PSS_LEN = 128
    SAMPLE_RATE = 3840000 * (2 ** NFFT) // 256
    CIC_DEC = SAMPLE_RATE // 1920000
    print(f'CIC decimation = {CIC_DEC}')
    MULT_REUSE_FFT = MULT_REUSE // CIC_DEC if MULT_REUSE > 2 else 1 # insert valid = 0 cycles if needed
    CLK_FREQ = str(int(SAMPLE_RATE * MULT_REUSE_FFT))
    print(f'system clock frequency = {CLK_FREQ} Hz')
    print(f'sample clock frequency = {SAMPLE_RATE} Hz')
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters['OUT_DW'] = OUT_DW
    parameters['TAP_DW'] = TAP_DW
    parameters['PSS_LEN'] = PSS_LEN
    parameters['ALGO'] = ALGO
    parameters['WINDOW_LEN'] = WINDOW_LEN
    parameters['HALF_CP_ADVANCE'] = HALF_CP_ADVANCE
    parameters['NFFT'] = NFFT
    parameters['USE_TAP_FILE'] = USE_TAP_FILE
    parameters['MULT_REUSE'] = MULT_REUSE
    parameters['MULT_REUSE_FFT'] = MULT_REUSE_FFT
    parameters['CLK_FREQ'] = CLK_FREQ
    parameters['INITIAL_DETECTION_SHIFT'] = INITIAL_DETECTION_SHIFT
    parameters_no_taps = parameters.copy()
    folder = 'Decimator_to_FFT_' + '_'.join(('{}={}'.format(*i) for i in parameters_no_taps.items())) + '_' + FILE
    sim_build= os.path.join('sim_build', folder)
    os.environ['TEST_FILE'] = FILE

    if USE_TAP_FILE:
        FFT_LEN = 2 ** NFFT
        CP_LEN = int(18 * FFT_LEN / 256)
        CP_ADVANCE = CP_LEN // 2
        os.makedirs(sim_build, exist_ok=True)

        file_path = os.path.abspath(os.path.join(tests_dir, '../tools/generate_FFT_demod_tap_file.py'))
        spec = importlib.util.spec_from_file_location("generate_FFT_demod_tap_file", file_path)
        generate_FFT_demod_tap_file = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generate_FFT_demod_tap_file)
        generate_FFT_demod_tap_file.main(['--NFFT', str(NFFT),'--CP_LEN', str(CP_LEN), '--CP_ADVANCE', str(CP_ADVANCE),
                                            '--OUT_DW', str(OUT_DW), '--path', sim_build])

    for N_id_2 in range(3):
        os.makedirs(sim_build, exist_ok=True)
        file_path = os.path.abspath(os.path.join(tests_dir, '../tools/generate_PSS_tap_file.py'))
        spec = importlib.util.spec_from_file_location("generate_PSS_tap_file", file_path)
        generate_PSS_tap_file = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generate_PSS_tap_file)
        generate_PSS_tap_file.main(['--PSS_LEN', str(PSS_LEN),'--TAP_DW', str(TAP_DW), '--N_id_2', str(N_id_2), '--path', sim_build])

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
        compile_args = compile_args,
        waves=True
    )

@pytest.mark.parametrize("FILE", ["772850KHz_3840KSPS_low_gain"])
def test_recording(FILE):
    test(IN_DW = 32, OUT_DW = 32, TAP_DW = 32, ALGO = 0, WINDOW_LEN = 8, HALF_CP_ADVANCE = 1, NFFT = 8, USE_TAP_FILE = 1, MULT_REUSE = 0, INITIAL_DETECTION_SHIFT = 3, FILE = FILE)

if __name__ == '__main__':
    os.environ['PLOTS'] = "1"
    # os.environ['SIM'] = 'verilator'
    # test(IN_DW = 32, OUT_DW = 32, TAP_DW = 32, ALGO = 0, WINDOW_LEN = 8, HALF_CP_ADVANCE = 1, NFFT = 8, USE_TAP_FILE = 1, MULT_REUSE = 0, INITIAL_DETECTION_SHIFT = 3, FILE = '772850KHz_3840KSPS_low_gain')
    test(IN_DW = 32, OUT_DW = 32, TAP_DW = 32, ALGO = 1, WINDOW_LEN = 8, HALF_CP_ADVANCE = 1, NFFT = 8, USE_TAP_FILE = 1, MULT_REUSE = 0, INITIAL_DETECTION_SHIFT = 4)
