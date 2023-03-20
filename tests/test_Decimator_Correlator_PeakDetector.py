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

        tests_dir = os.path.abspath(os.path.dirname(__file__))
        model_file = os.path.abspath(os.path.join(tests_dir, '../model/PSS_correlator.py'))

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())

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

@cocotb.test()
async def simple_test(dut):
    tb = TB(dut)
    handle = sigmf.sigmffile.fromfile('../../tests/30720KSPS_dl_signal.sigmf-data')
    waveform = handle.read_samples()
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform = scipy.signal.decimate(waveform, 16//2, ftype='fir')
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= 2 ** (tb.IN_DW // 2 - 1)
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)

    await tb.cycle_reset()

    num_items = 2000
    rx_counter = 0
    in_counter = 0
    received = np.empty(num_items, int)
    received_correlator = []
    received_data = []
    while rx_counter < num_items:
        await RisingEdge(dut.clk_i)
        data = (((int(waveform[in_counter].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
              + ((int(waveform[in_counter].real)) & ((2 ** (tb.IN_DW // 2)) - 1))) & ((2 ** tb.IN_DW) - 1)
        dut.s_axis_in_tdata.value = data
        dut.s_axis_in_tvalid.value = 1
        in_counter += 1

        # print(f'{dut.m_axis_cic_tvalid.value.integer} + {dut.m_axis_cic_tdata.value.integer}')

        if dut.m_axis_correlator_debug_tvalid == 1:
            received_correlator.append(dut.m_axis_correlator_debug_tdata.value.integer)

        if dut.m_axis_cic_debug_tvalid.value.binstr == '1':
            received_data.append(1j*_twos_comp(dut.m_axis_cic_debug_tdata.value.integer & (2**(tb.OUT_DW//2) - 1), tb.OUT_DW//2)
                + _twos_comp((dut.m_axis_cic_debug_tdata.value.integer>>(tb.OUT_DW//2)) & (2**(tb.OUT_DW//2) - 1), tb.OUT_DW//2))

        received[rx_counter] = dut.peak_detected_o.value.integer
        rx_counter += 1

    peak_pos = np.argmax(received)
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, (ax1, ax2) = plt.subplots(2,1)
        ax1.plot(received_correlator)
        ax1.set_title('correlation')
        ax2.plot(received)
        ax2.set_title('peak detected')
        plt.show()
    print(f'highest peak at {peak_pos}')
    assert peak_pos == 840


# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("ALGO", [0, 1])
@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("WINDOW_LEN", [8])
def test(IN_DW, OUT_DW, TAP_DW, ALGO, WINDOW_LEN):
    dut = 'Decimator_Correlator_PeakDetector'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'atan.sv'),
        os.path.join(rtl_dir, 'atan2.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv'),
        os.path.join(rtl_dir, 'CIC/cic_d.sv'),
        os.path.join(rtl_dir, 'CIC/comb.sv'),
        os.path.join(rtl_dir, 'CIC/downsampler.sv'),
        os.path.join(rtl_dir, 'CIC/integrator.sv')
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
    parameters['WINDOW_LEN'] = WINDOW_LEN

    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}
    parameters_no_taps = parameters.copy()
    sim_build='sim_build/Decimator_to_PeakDetector_' + '_'.join(('{}={}'.format(*i) for i in parameters_no_taps.items()))

    N_id_2 = 2
    # parameters['TAP_FILE'] = f'\"../../{sim_build}/PSS_taps_{N_id_2}.hex\"'
    os.environ['TAP_FILE'] = f'{rtl_dir}/../{sim_build}/PSS_taps_{N_id_2}.hex'

    os.makedirs(sim_build, exist_ok=True)
    file_path = os.path.abspath(os.path.join(tests_dir, '../tools/generate_PSS_tap_file.py'))
    spec = importlib.util.spec_from_file_location("generate_PSS_tap_file", file_path)
    generate_PSS_tap_file = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generate_PSS_tap_file)
    generate_PSS_tap_file.main(['--PSS_LEN', str(PSS_LEN),'--TAP_DW', str(TAP_DW), '--N_id_2', str(N_id_2), '--path', sim_build])

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
        force_compile=True
    )

if __name__ == '__main__':
    os.environ['PLOTS'] = "1"
    test(IN_DW=32, OUT_DW=32, TAP_DW=32, ALGO=0, WINDOW_LEN=8)
