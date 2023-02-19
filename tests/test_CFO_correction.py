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
        self.MULT_REUSE = int(dut.MULT_REUSE.value)
        self.CIC_OUT_DW = int(dut.CIC_OUT_DW.value)
        self.DDS_PHASE_DW = int(dut.DDS_PHASE_DW.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        tests_dir = os.path.abspath(os.path.dirname(__file__))
        model_dir = os.path.abspath(os.path.join(tests_dir, '../model/PSS_correlator.py'))
        spec = importlib.util.spec_from_file_location('PSS_correlator', model_dir)
        foo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(foo)
        self.model = foo.Model(self.IN_DW, self.OUT_DW, self.TAP_DW, self.PSS_LEN, self.PSS_LOCAL, self.ALGO)

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())
        cocotb.start_soon(self.model_clk(CLK_PERIOD_NS, 'ns'))

    async def model_clk(self, period, period_units):
        timer = Timer(period, period_units)
        while True:
            self.model.tick()
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
        self.model.reset()

@cocotb.test()
async def simple_test(dut):
    tb = TB(dut)
    handle = sigmf.sigmffile.fromfile('../../tests/30720KSPS_dl_signal.sigmf-data')
    waveform = handle.read_samples()
    fs = 30720000
    CFO = int(os.getenv('CFO'))
    print(f'CFO = {CFO} Hz')
    waveform *= np.exp(np.arange(len(waveform))*1j*2*np.pi*CFO/fs)
    waveform /= max(waveform.real.max(), waveform.imag.max())
    decimation_factor = 8
    FFT_LEN  = 2048 // decimation_factor
    waveform = scipy.signal.decimate(waveform, decimation_factor, ftype='fir')
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= 2 ** (tb.IN_DW // 2 - 1) - 1
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)

    requested_CFO_corr = int(os.environ['CFO_CORR'])
    print(f'requested CFO correction is {requested_CFO_corr} Hz')
    eff_CFO_corr_norm = int(np.round(requested_CFO_corr) / 3840000 * (2**tb.DDS_PHASE_DW - 1))
    eff_CFO_corr_hz = eff_CFO_corr_norm * 3840000 / (2**tb.DDS_PHASE_DW - 1)
    print(f'effictive CFO correction is {eff_CFO_corr_hz} Hz')

    await tb.cycle_reset()
    dut.CFO_norm_in.value = eff_CFO_corr_norm
    dut.CFO_norm_valid_in.value = 1
    await RisingEdge(dut.clk_i)
    dut.CFO_norm_valid_in.value = 0

    num_items = 500
    rx_counter = 0
    in_counter = 0
    received = np.empty(num_items, int)
    clk_div = 0
    C0 = []
    C1 = []
    C_DW = int(tb.CIC_OUT_DW + tb.TAP_DW + 2 + 2*np.ceil(np.log2(tb.PSS_LEN)))
    while rx_counter < num_items:
        await RisingEdge(dut.clk_i)
        if clk_div < (decimation_factor - 1):
            dut.s_axis_in_tvalid.value = 0
            clk_div += 1
        else:
            clk_div = 0
            data = (((int(waveform[in_counter].imag)  & (2 ** (tb.IN_DW // 2) - 1)) << (tb.IN_DW // 2)) \
                  + ((int(waveform[in_counter].real)) & (2 ** (tb.IN_DW // 2) - 1))) & (2 ** tb.IN_DW - 1)
            dut.s_axis_in_tdata.value = data
            dut.s_axis_in_tvalid.value = 1
            tb.model.set_data(data)
            in_counter += 1

        if dut.m_axis_correlator_debug_tvalid.value.integer == 1:
            received[rx_counter] = dut.m_axis_correlator_debug_tdata.value.integer
            C0.append(_twos_comp(dut.C0.value.integer & (2 ** (C_DW // 2) - 1),C_DW // 2) \
                    + 1j * _twos_comp((dut.C0.value.integer >> (C_DW // 2)) & (2 ** (C_DW // 2) - 1), C_DW // 2))
            C1.append(_twos_comp(dut.C1.value.integer & (2 ** (C_DW // 2) - 1), C_DW // 2) \
                    + 1j * _twos_comp((dut.C1.value.integer >> (C_DW // 2)) & (2 ** (C_DW // 2) - 1), C_DW // 2))
            rx_counter  += 1

    PSS_LEN = 128
    ssb_start = np.argmax(received) - PSS_LEN
    received = np.array(received)[PSS_LEN:]
    print(f'max hdl {max(received)}')
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, ax = plt.subplots(1, 1)
        ax.plot(np.sqrt(received))
        ax.axvline(x = ssb_start, color = 'y', linestyle = '--', label = 'axvline - full height')
        plt.show()
    print(f'max correlation is {received[ssb_start]} at {ssb_start}')

    if tb.ALGO == 0:
        prod = C0[ssb_start+PSS_LEN] * np.conj(C1[ssb_start+PSS_LEN])
        # detectedCFO = np.arctan2(prod.imag, prod.real)
        detectedCFO = np.angle(prod)
        detectedCFO_Hz = detectedCFO / (2*np.pi) * (fs/decimation_factor/2) / 64 # there is another 2x decimation inside the hdl 
        print(f'detected CFO = {detectedCFO_Hz} Hz')
    else:
        print('CFO estimation is not possible with ALGO=1')

    PSS = np.zeros(FFT_LEN, 'complex')
    PSS[FFT_LEN//2-64:][:127] = py3gpp.nrPSS(2)
    taps = np.fft.ifft(np.fft.fftshift(PSS))
    ssb_start_model = 568
    C0 = np.vdot(waveform[ssb_start_model:][:64], taps[:64])
    C1 = np.vdot(waveform[ssb_start_model+64:][:64], taps[64:][:64])
    prod = C0 * np.conj(C1)
    # detectedCFO = np.arctan2(prod.imag, prod.real)
    detectedCFO = np.angle(prod)
    detectedCFO_Hz_model = detectedCFO / (2*np.pi) * (fs/decimation_factor) / 64
    print(f'detected CFO (model) = {detectedCFO_Hz_model} Hz')
    # TODO: why do cases with active CFO correction need more tolerance?
    if tb.ALGO == 0:
        if CFO != 0:
            if eff_CFO_corr_hz == 0:
                assert (np.abs(detectedCFO_Hz - detectedCFO_Hz_model - eff_CFO_corr_hz))/np.abs(CFO) < 0.05
            else:
                assert (np.abs(detectedCFO_Hz - detectedCFO_Hz_model - eff_CFO_corr_hz))/np.abs(CFO) < 0.08
        else:
            if eff_CFO_corr_hz == 0:
                assert np.abs(detectedCFO_Hz - detectedCFO_Hz_model - eff_CFO_corr_hz) < 50
            else:
                assert np.abs(detectedCFO_Hz - detectedCFO_Hz_model - eff_CFO_corr_hz) < 60

    assert ssb_start == 283
    assert len(received) == num_items - PSS_LEN

@pytest.mark.parametrize("ALGO", [0])
@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("CFO", [0, 6500, -5500])
@pytest.mark.parametrize("MULT_REUSE", [1, 16])
@pytest.mark.parametrize("CFO_CORR", [0, 1000, -1000])
@pytest.mark.parametrize("PSS_CORRELATOR_MR", [0, 1])
def test(IN_DW, OUT_DW, TAP_DW, ALGO, CFO, MULT_REUSE, CFO_CORR, PSS_CORRELATOR_MR):
    dut = 'test_CFO_correction'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv'),
        os.path.join(rtl_dir, 'PSS_correlator_mr.sv'),
        os.path.join(rtl_dir, 'CIC/cic_d.sv'),
        os.path.join(rtl_dir, 'CIC/comb.sv'),
        os.path.join(rtl_dir, 'CIC/downsampler.sv'),
        os.path.join(rtl_dir, 'CIC/integrator.sv'),
        os.path.join(rtl_dir, 'complex_multiplier', 'complex_multiplier.v'),
        os.path.join(rtl_dir, 'DDS', 'dds.sv')
    ]
    includes = [
        os.path.join(rtl_dir, 'CIC')
    ]

    PSS_LEN = 128
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters['OUT_DW'] = OUT_DW
    parameters['TAP_DW'] = TAP_DW
    parameters['PSS_LEN'] = PSS_LEN
    parameters['ALGO'] = ALGO
    parameters['MULT_REUSE'] = MULT_REUSE
    parameters['PSS_CORRELATOR_MR'] = PSS_CORRELATOR_MR

    # imaginary part is in upper 16 Bit
    PSS = np.zeros(PSS_LEN, 'complex')
    PSS[0:-1] = py3gpp.nrPSS(2)
    taps = np.fft.ifft(np.fft.fftshift(PSS))
    taps /= max(taps.real.max(), taps.imag.max())
    taps *= 2 ** (TAP_DW // 2 - 1) - 1
    # for i in range(10):
    #     print(f'taps[{i}] = {taps[i]}')
    parameters['PSS_LOCAL'] = 0
    for i in range(len(taps)):
        parameters['PSS_LOCAL'] += ((int(np.imag(taps[i])) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * i + TAP_DW // 2)) \
                                +  ((int(np.real(taps[i])) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * i))
    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}
    os.environ['CFO'] = str(CFO)
    os.environ['CFO_CORR'] = str(CFO_CORR)
    
    parameters_dirname = parameters.copy()
    del parameters_dirname['PSS_LOCAL']
    parameters_dirname['CFO'] = CFO
    parameters_dirname['CFO_CORR'] = CFO_CORR
    sim_build='sim_build/' + '_'.join(('{}={}'.format(*i) for i in parameters_dirname.items()))
    
    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        includes=includes,
        toplevel=toplevel,
        module=module,
        # defines = {"LUT_PATH":"tests"},
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env,
        testcase='simple_test',
        compile_args = ['-DLUT_PATH=\"../../tests\"'],
        force_compile=True
    )

if __name__ == '__main__':
    # os.environ['PLOTS'] = "1"
    # this setup does not require output truncation
    test(IN_DW = 32, OUT_DW = 48, TAP_DW = 18, ALGO = 0, CFO = 2500, MULT_REUSE = 16, CFO_CORR = 0, PSS_CORRELATOR_MR = 0)
