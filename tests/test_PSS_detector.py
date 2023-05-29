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
        self.USE_MODE = int(dut.USE_MODE.value)
        self.USE_TAP_FILE = int(dut.USE_TAP_FILE.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        tests_dir = os.path.abspath(os.path.dirname(__file__))
        if self.USE_TAP_FILE:
            self.TAP_FILE_2 = os.environ["TAP_FILE_2"]
            self.PSS_LOCAL_2 = 0
        else:
            self.TAP_FILE_2 = ""
            self.PSS_LOCAL_2 =  int(dut.PSS_LOCAL_2.value)

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())

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
    handle = sigmf.sigmffile.fromfile('../../tests/30720KSPS_dl_signal.sigmf-data')
    waveform = handle.read_samples()
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform = scipy.signal.decimate(waveform, 16, ftype='fir')
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= 2 ** (tb.IN_DW // 2 - 1)
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)

    await tb.cycle_reset()

    if tb.USE_MODE:
        MAX_CLK_CNT = int(1.92e6 * 0.025)
    else:
        MAX_CLK_CNT = 3000
    clk_cnt = 0
    in_counter = 0
    received = []
    received_correlator = []
    dut.clear_ni.value = 1
    while clk_cnt < MAX_CLK_CNT:
        await RisingEdge(dut.clk_i)
        data = (((int(waveform[in_counter].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
              + ((int(waveform[in_counter].real)) & ((2 ** (tb.IN_DW // 2)) - 1))) & ((2 ** tb.IN_DW) - 1)
        dut.s_axis_in_tdata.value = data
        dut.s_axis_in_tvalid.value = 1
        in_counter += 1

        if dut.m_axis_correlator_debug_tvalid.value == 1:
            received_correlator.append(dut.m_axis_correlator_debug_tdata.value.integer)

        if dut.N_id_2_valid_o.value == 1:
            print(f'detected N_id_2 = {dut.N_id_2_o.value.integer}')
            received.append(clk_cnt)
        clk_cnt += 1
        if ((clk_cnt % (1920)) == 0):
            print(f'sim time {clk_cnt // 1920} ms')

    print(f'received peaks at {received}')
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, (ax1, ax2) = plt.subplots(2,1)
        ax1.plot(received_correlator)
        peak_data = np.zeros(len(received_correlator))
        for i in received:
            peak_data[i] = 1
        ax2.plot(peak_data)
        plt.show()
    assert 429 in received

# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("ALGO", [0, 1])
@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("CFO_DW", [24])
@pytest.mark.parametrize("DDS_DW", [24])
@pytest.mark.parametrize("WINDOW_LEN", [8])
@pytest.mark.parametrize("USE_MODE", [0])
@pytest.mark.parametrize("USE_TAP_FILE", [0, 1])
@pytest.mark.parametrize("VARIABLE_NOISE_LIMIT", [0, 1])
@pytest.mark.parametrize("VARIABLE_DETECTION_FACTOR", [0, 1])
def test(IN_DW, OUT_DW, TAP_DW, CFO_DW, DDS_DW, ALGO, WINDOW_LEN, USE_MODE, USE_TAP_FILE, VARIABLE_NOISE_LIMIT, VARIABLE_DETECTION_FACTOR):
    dut = 'PSS_detector'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'AXIS_FIFO.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'atan.sv'),
        os.path.join(rtl_dir, 'atan2.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv'),
        os.path.join(rtl_dir, 'PSS_correlator_mr.sv'),
        os.path.join(rtl_dir, 'PSS_detector_regmap.sv'),
        os.path.join(rtl_dir, 'AXI_lite_interface.sv'),
        os.path.join(rtl_dir, 'CFO_calc.sv'),
        os.path.join(rtl_dir, 'complex_multiplier/complex_multiplier.sv')
    ]
    includes = []

    PSS_LEN = 128
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters['OUT_DW'] = OUT_DW
    parameters['TAP_DW'] = TAP_DW
    parameters['CFO_DW'] = CFO_DW
    parameters['DDS_DW'] = DDS_DW
    parameters['PSS_LEN'] = PSS_LEN
    parameters['ALGO'] = ALGO
    parameters['WINDOW_LEN'] = WINDOW_LEN
    parameters['USE_MODE'] = USE_MODE
    parameters['USE_TAP_FILE'] = USE_TAP_FILE
    parameters['VARIABLE_NOISE_LIMIT'] = VARIABLE_NOISE_LIMIT
    parameters['VARIABLE_DETECTION_FACTOR'] = VARIABLE_DETECTION_FACTOR
    parameters['CIC_RATE'] = 1
    parameters_no_taps = parameters.copy()
    folder = '_'.join(('{}={}'.format(*i) for i in parameters_no_taps.items()))
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
            np.savetxt(sim_build + f'_PSS_{i}_taps.txt', PSS_taps, fmt = '%x', delimiter = ' ')

    compile_args = []
    if os.environ.get('SIM') == 'verilator':
        compile_args = ['--no-timing', '-Wno-fatal', '-CFLAGS', '-DVL_VALUE_STRING_MAX_WORDS=256']

    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        includes=includes,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        testcase='simple_test',
        force_compile=True,
        waves=True,
        compile_args=compile_args
    )

@cocotb.test()
async def axi_tb(dut):
    tb = TB(dut)

    await tb.cycle_reset()

    axi_master = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "s_axi"), dut.clk_i, dut.reset_ni, reset_active_level = False)
    
    addr = 0
    data = await axi_master.read_dword(4 * addr)
    data = int(data)
    assert data == 0x00010061

    addr = 4
    data = await axi_master.read_dword(4 * addr)
    data = int(data)
    assert data == 0x69696969

def test_axi():
    dut = 'PSS_detector'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    sim_build='sim_build/PSS_detector_axi_test/'

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'AXIS_FIFO.sv'),
        os.path.join(rtl_dir, 'CIC/cic_d.sv'),
        os.path.join(rtl_dir, 'CIC/comb.sv'),
        os.path.join(rtl_dir, 'CIC/downsampler.sv'),
        os.path.join(rtl_dir, 'CIC/integrator.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'atan.sv'),
        os.path.join(rtl_dir, 'atan2.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv'),
        os.path.join(rtl_dir, 'PSS_correlator_mr.sv'),
        os.path.join(rtl_dir, 'PSS_detector_regmap.sv'),
        os.path.join(rtl_dir, 'AXI_lite_interface.sv'),
        os.path.join(rtl_dir, 'CFO_calc.sv'),
        os.path.join(rtl_dir, 'complex_multiplier/complex_multiplier.sv')
    ]

    includes = [
        os.path.join(rtl_dir, 'CIC')
    ]

    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=toplevel,
        module=module,
        includes=includes,
        sim_build=sim_build,
        testcase='axi_tb',
        force_compile=True,
        waves=True,
    )

if __name__ == '__main__':
    os.environ['PLOTS'] = "1"
    # os.environ['SIM'] = 'verilator'
    test(IN_DW=32, OUT_DW=32, TAP_DW=32, ALGO=0, WINDOW_LEN=8, USE_MODE=0, USE_TAP_FILE=1, DDS_DW = 24, CFO_DW = 24, VARIABLE_NOISE_LIMIT = 0, VARIABLE_DETECTION_FACTOR = 0)
    # test_axi()
