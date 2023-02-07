import numpy as np
import scipy
import os
import pytest
import logging
import importlib
import matplotlib.pyplot as plt
import os

import cocotb
import cocotb_test.simulator
from cocotb.clock import Clock
from cocotb.triggers import Timer
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
        self.PSS_LOCAL = int(dut.PSS_LOCAL.value)
        self.ALGO = int(dut.ALGO.value)
        self.WINDOW_LEN = int(dut.WINDOW_LEN.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        # tests_dir = os.path.abspath(os.path.dirname(__file__))
        model_file = os.path.abspath(os.path.join(tests_dir, '../model/PSS_correlator.py'))
        spec = importlib.util.spec_from_file_location('PSS_correlator', model_file)
        foo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(foo)
        self.PSS_correlator_model = foo.Model(self.IN_DW, self.OUT_DW, self.TAP_DW, self.PSS_LEN, self.PSS_LOCAL, self.ALGO) 

        model_file = os.path.abspath(os.path.join(tests_dir, '../model/peak_detector.py'))
        spec = importlib.util.spec_from_file_location('peak_detector', model_file)
        foo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(foo)
        self.peak_detector_model = foo.Model(self.OUT_DW, self.WINDOW_LEN)

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())
        cocotb.start_soon(self.model_clk(CLK_PERIOD_NS, 'ns'))

    async def model_clk(self, period, period_units):
        timer = Timer(period, period_units)
        while True:
            self.PSS_correlator_model.tick()
            self.peak_detector_model.tick()
            await timer

    async def generate_input(self):
        pass

    async def cycle_reset(self):
        self.dut.s_axis_in_tvalid.value = 0
        self.dut.reset_ni.setimmediatevalue(1)
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 0
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 1
        await RisingEdge(self.dut.clk_i)
        self.PSS_correlator_model.reset()
        self.peak_detector_model.reset()

@cocotb.test()
async def simple_test(dut):
    tb = TB(dut)
    CFO = int(os.getenv('CFO'))
    handle = sigmf.sigmffile.fromfile('../../tests/30720KSPS_dl_signal.sigmf-data')
    waveform = handle.read_samples()
    fs = 30720000
    print(f'CFO = {CFO} Hz')
    waveform *= np.exp(np.arange(len(waveform))*1j*2*np.pi*CFO/fs)
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform = scipy.signal.decimate(waveform, 16//2, ftype='fir')  # decimate to 3.840 MSPS
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= (2 ** (tb.IN_DW // 2 - 1) - 1)
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)

    await tb.cycle_reset()

    rx_counter = 0
    in_counter = 0
    received = []
    received_correlator = []
    received_fft = []
    received_fft_demod = []
    received_fft_ideal = []
    received_PBCH = []
    received_SSS = []
    fft_started = False
    wait_cycles = 0
    CP_LEN = 18
    FFT_SIZE = 256
    DETECTOR_LATENCY = 17
    SSS_delay = CP_LEN - DETECTOR_LATENCY
    FFT_OUT_DW = 32
    max_tx = 2000
    while in_counter < 50000:
        await RisingEdge(dut.clk_i)
        if in_counter < max_tx:
            data = (((int(waveform[in_counter].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
                + ((int(waveform[in_counter].real)) & ((2 ** (tb.IN_DW // 2)) - 1))) & ((2 ** tb.IN_DW) - 1)
            dut.s_axis_in_tdata.value = data
            dut.s_axis_in_tvalid.value = 1
            tb.PSS_correlator_model.set_data(data)
        else:
            dut.s_axis_in_tvalid.value = 0

        #print(f"data[{in_counter}] = {(int(waveform[in_counter].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)):4x} {(int(waveform[in_counter].real)  & ((2 ** (tb.IN_DW // 2)) - 1)):4x}")
        in_counter += 1

        if dut.m_axis_correlator_debug_tvalid == 1:
            received_correlator.append(dut.m_axis_correlator_debug_tdata.value.integer)

        received.append(dut.peak_detected_debug_o.value.integer)
        rx_counter += 1
        # if dut.peak_detected_debug_o.value.integer == 1:
        #     print(f'{rx_counter}: peak detected')

        # if dut.sync_wait_counter.value.integer != 0:
        #     print(f'{rx_counter}: wait_counter = {dut.sync_wait_counter.value.integer}')

        # print(f'{dut.m_axis_out_tvalid.value.binstr}  {dut.m_axis_out_tdata.value.binstr}')

        if dut.peak_detected_debug_o.value.integer == 1:
            print(f'peak pos = {in_counter}')

        if dut.peak_detected_debug_o.value.integer == 1 or wait_cycles > 0:
            if wait_cycles < SSS_delay:
                wait_cycles += 1
            else:
                received_fft_ideal.append(waveform[in_counter])

        if dut.fft_demod_PBCH_start_o == 1:
            print(f'{rx_counter}: PBCH start')

        if dut.fft_demod_SSS_start_o == 1:
            print(f'{rx_counter}: SSS start')

        if dut.m_axis_SSS_tdata.value.integer == 1:
            print(f'detected N_id_1 = {dut.m_axis_SSS_tdata.value.integer}')

        if dut.PBCH_valid_o.value.integer == 1:
            # print(f"rx PBCH[{len(received_PBCH):3d}] re = {dut.m_axis_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1):4x} " \
            #     "im = {(dut.m_axis_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1):4x}")
            received_PBCH.append(_twos_comp(dut.m_axis_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

        if dut.SSS_valid_o.value.integer == 1:
            # print(f"rx SSS[{len(received_SSS):3d}]")
            received_SSS.append(_twos_comp(dut.m_axis_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

        if dut.m_axis_out_tvalid.value.binstr == '1':
            # print(f'{rx_counter}: fft_demod {dut.m_axis_out_tdata.value}')
            received_fft_demod.append(_twos_comp(dut.m_axis_out_tdata.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.m_axis_out_tdata.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

        if fft_started:
            # print(f'{rx_counter}: fft_debug {dut.fft_result_debug_o.value}')
            received_fft.append(_twos_comp(dut.fft_result_debug_o.value.integer & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2)
                + 1j * _twos_comp((dut.fft_result_debug_o.value.integer>>(FFT_OUT_DW//2)) & (2**(FFT_OUT_DW//2) - 1), FFT_OUT_DW//2))

    assert len(received_SSS) == FFT_SIZE
    # received_SSS_sym = np.fft.fftshift(received_fft_demod[256:][:256])
    received_SSS_sym = received_SSS
    SSS_START = 64
    SSS_LEN = 127
    received_SSS = received_SSS_sym[SSS_START:][:SSS_LEN]

    ideal_SSS_sym = np.fft.fftshift(np.fft.fft(received_fft_ideal[FFT_SIZE + CP_LEN:][:FFT_SIZE]))
    ideal_SSS = ideal_SSS_sym[SSS_START:][:SSS_LEN]
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        ax = plt.subplot(4, 2, 1)
        ax.plot(np.abs(ideal_SSS_sym))
        ax = plt.subplot(4, 2, 2)
        ax.plot(np.abs(ideal_SSS))
        ax = plt.subplot(4, 2, 3)
        ax.plot(np.real(ideal_SSS), 'r-')
        ax = ax.twinx()
        ax.plot(np.imag(ideal_SSS), 'b-')
        ax = plt.subplot(4, 2, 4)
        ax.plot(np.real(ideal_SSS),
            np.imag(ideal_SSS), '.')

        ax = plt.subplot(4, 2, 5)
        ax.plot(np.abs((received_SSS_sym)))
        ax = plt.subplot(4, 2, 6)
        ax.plot(np.abs(received_SSS))
        ax = plt.subplot(4, 2, 7)
        ax.plot(np.real(received_SSS), 'r-')
        ax = ax.twinx()
        ax.plot(np.imag(received_SSS), 'b-')
        ax = plt.subplot(4, 2, 8)
        ax.plot(np.real(received_SSS),
            np.imag(received_SSS), '.')
        plt.show()

    received_PBCH= received_PBCH[9:][:FFT_SIZE-8*2 - 1]
    received_PBCH_ideal = np.fft.fftshift(np.fft.fft(received_fft_ideal[:FFT_SIZE]))[8:][:FFT_SIZE-8*2]
    received_PBCH_ideal = (received_PBCH_ideal.real.astype(int) + 1j * received_PBCH_ideal.imag.astype(int))
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, axs = plt.subplots(3, 1, figsize=(5, 10))
        for i in range(len(received_SSS)):
            axs[0].plot(np.real(received_SSS), np.imag(received_SSS), '.')
        for i in range(len(received_PBCH)):
            axs[1].plot(np.real(received_PBCH), np.imag(received_PBCH), '.')
            axs[2].plot(np.real(received_PBCH_ideal), np.imag(received_PBCH_ideal), '.')
        plt.show()

    peak_pos = np.argmax(received)
    print(f'highest peak at {peak_pos}')

    # assert len(received_SSS) == 127
    # for i in range(FFT_SIZE):
    #     print(f'core : {received_fft[i]}')
    #     print(f'demod: {received_fft_demod[i]}')
    # for i in range(len(received_PBCH)):
    #     print(f'{received_PBCH[i]} <-> {np.fft.fftshift(np.fft.fft(received_fft_ideal[:256]))}')
    # print('--------------')
    # for i in range(len(received_PBCH)):
    #     print(received_PBCH_ideal[i])

    NFFT = 8
    scaling_factor = 2**(tb.IN_DW + NFFT - tb.OUT_DW) # FFT core is in truncation mode
    ideal_SSS = ideal_SSS.real / scaling_factor + 1j * ideal_SSS.imag / scaling_factor
    error_signal = received_SSS - ideal_SSS
    # for i in range(len(received_SSS)):
    #     if received_SSS[i] != ideal_SSS[i]:
    #         print(f'{received_SSS[i]} != {ideal_SSS[i]}')
    assert max(np.abs(error_signal)) < max(np.abs(received_SSS)) * 0.01

    # assert np.array_equal(received_PBCH, received_PBCH_ideal)  # TODO: make this pass
    assert peak_pos == 840
    corr = np.zeros(335)
    for i in range(335):
        sss = py3gpp.nrSSS(i)
        corr[i] = np.abs(np.vdot(sss, received_SSS))
    detected_NID1 = np.argmax(corr)
    assert detected_NID1 == 209


# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("ALGO", [0, 1])
@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("WINDOW_LEN", [8])
@pytest.mark.parametrize("CFO", [0, 100])
def test(IN_DW, OUT_DW, TAP_DW, ALGO, WINDOW_LEN, CFO):
    dut = 'Decimator_to_SSS_detector'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    unisim_dir = os.path.join(rtl_dir, '../submodules/FFT/submodules/XilinxUnisimLibrary/verilog/src/unisims')
    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv'),
        os.path.join(rtl_dir, 'SSS_detector.sv'),
        os.path.join(rtl_dir, 'LFSR/LFSR.sv'),        
        os.path.join(rtl_dir, 'FFT_demod.sv'),
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
        os.path.join(rtl_dir, '../submodules/FFT/submodules/XilinxUnisimLibrary/verilog/src/glbl.v')
    ]
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
    os.environ['CFO'] = str(CFO)

    # imaginary part is in upper 16 Bit
    PSS = np.zeros(PSS_LEN, 'complex')
    PSS[0:-1] = py3gpp.nrPSS(2)
    taps = np.fft.ifft(np.fft.fftshift(PSS))
    taps /= max(taps.real.max(), taps.imag.max())
    taps *= 2 ** (TAP_DW // 2 - 1)
    parameters['PSS_LOCAL'] = 0
    for i in range(len(taps)):
        parameters['PSS_LOCAL'] += \
            ((int(np.round(np.imag(taps[i]))) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * i + TAP_DW // 2)) \
            + ((int(np.round(np.real(taps[i]))) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * i))
    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}
    parameters_no_taps = parameters.copy()
    del parameters_no_taps['PSS_LOCAL']

    sim_build='sim_build/' + '_'.join(('{}={}'.format(*i) for i in parameters_no_taps.items()))
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
        compile_args = ['-sglbl', '-y' + unisim_dir]
    )

if __name__ == '__main__':
    os.environ['PLOTS'] = "1"
    test(IN_DW = 32, OUT_DW = 32, TAP_DW = 32, ALGO = 0, WINDOW_LEN = 8, CFO=100)