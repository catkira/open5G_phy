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
    FILE = '../../tests/' + os.environ['TEST_FILE'] + '.sigmf-data'
    handle = sigmf.sigmffile.fromfile(FILE)
    fs = handle.get_global_field(sigmf.SigMFFile.SAMPLE_RATE_KEY)
    waveform = handle.read_samples()
    waveform /= max(waveform.real.max(), waveform.imag.max())
    dec_factor = int(fs / 1920000)
    print(f'test_file = {FILE}')
    print(f'sample_rate = {fs}, decimation_factor = {dec_factor}')
    waveform = scipy.signal.decimate(waveform, dec_factor, ftype='fir')
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= 2 ** (tb.IN_DW // 2 - 1)
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)

    await tb.cycle_reset()

    if os.environ['TEST_FILE'] == '30720KSPS_dl_signal':
        num_items = 500
        expected_peak_pos = 416
    else:
        num_items = 1500
        expected_peak_pos = 1197
    rx_counter = 0
    in_counter = 0
    received = np.empty(num_items, int)
    while rx_counter < num_items:
        await RisingEdge(dut.clk_i)
        data = (((int(waveform[in_counter].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
              + ((int(waveform[in_counter].real)) & ((2 ** (tb.IN_DW // 2)) - 1))) & ((2 ** tb.IN_DW) - 1)
        dut.s_axis_in_tdata.value = data
        dut.s_axis_in_tvalid.value = 1
        tb.PSS_correlator_model.set_data(data)
        in_counter += 1

        #if dut.m_axis_out_tvalid == 1:
            # print(dut.m_axis_out_tdata.value.integer)
         #   received[rx_counter] = dut.m_axis_out_tdata.value.integer
            # print(f'rx hdl {received[rx_counter]}')
          #  rx_counter  += 1
        received[rx_counter] = dut.peak_detected_o.value.integer
        rx_counter += 1
        # print(dut.peak_detected_o.value.integer)


    peak_pos = np.argmax(received)
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, ax = plt.subplots()
        ax.plot(np.sqrt(received))
        # ax2=ax.twinx()
        # ax2.plot(np.sqrt(received_model), 'r-')
        # ax.axvline(x = ssb_start, color = 'y', linestyle = '--', label = 'axvline - full height')
        plt.show()
    print(f'highest peak at {peak_pos}')
    assert peak_pos == 416

# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("ALGO", [0, 1])
@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("WINDOW_LEN", [8])
@pytest.mark.parametrize("DETECTION_SHIFT", [4])
def test(IN_DW, OUT_DW, TAP_DW, ALGO, DETECTION_SHIFT, WINDOW_LEN, FILE = '30720KSPS_dl_signal'):
    dut = 'PSS_correlator_with_peak_detector'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv')
    ]
    includes = []

    PSS_LEN = 128
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters['OUT_DW'] = OUT_DW
    parameters['TAP_DW'] = TAP_DW
    parameters['PSS_LEN'] = PSS_LEN
    parameters['ALGO'] = ALGO
    parameters['WINDOW_LEN'] = WINDOW_LEN
    parameters['DETECTION_SHIFT'] = DETECTION_SHIFT
    os.environ['TEST_FILE'] = FILE

    if FILE == '30720KSPS_dl_signal':
        N_id_2 = 2
    else:
        N_id_2 = 0

    # imaginary part is in upper 16 Bit
    PSS = np.zeros(PSS_LEN, 'complex')
    PSS[0:-1] = py3gpp.nrPSS(N_id_2)
    taps = np.fft.ifft(np.fft.fftshift(PSS))
    taps /= max(taps.real.max(), taps.imag.max())
    taps *= 2 ** (TAP_DW // 2 - 1)
    parameters['PSS_LOCAL'] = 0
    for i in range(len(taps)):
        parameters['PSS_LOCAL'] += ((int(np.round(np.imag(taps[i]))) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * i + TAP_DW // 2)) \
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
        waves=True,
        testcase='simple_test',
        force_compile=True
    )

@pytest.mark.parametrize("FILE", ["772850KHz_3840KSPS_low_gain"])
def test_recording(FILE):
    test(IN_DW = 32, OUT_DW = 32, TAP_DW = 32, WINDOW_LEN = 8, ALGO = 0, DETECTION_SHIFT = 4, FILE = FILE)

if __name__ == '__main__':
    os.environ['PLOTS'] = '1'
    test_recording("772850KHz_3840KSPS_low_gain")
    # test(IN_DW = 32, OUT_DW = 32, TAP_DW = 32, WINDOW_LEN = 8, DETECTION_SHIFT = 4, ALGO = 0)
