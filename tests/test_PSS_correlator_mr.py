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
        self.MULT_REUSE = int(dut.MULT_REUSE.value)

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
    waveform = scipy.signal.decimate(waveform, 16, ftype='fir')
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= 2 ** (tb.IN_DW // 2 - 1) - 1
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)
    await tb.cycle_reset()

    num_items = 500
    rx_counter = 0
    rx_counter_model = 0
    in_counter = 0
    received = np.empty(num_items, int)
    received_model = np.empty(num_items, int)
    clk_div = 0
    clk_decimation = 16
    while rx_counter < num_items:
        await RisingEdge(dut.clk_i)
        if clk_div < (clk_decimation - 1):
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

        if dut.m_axis_out_tvalid == 1:
            # print(f'{rx_counter}: rx hdl {dut.m_axis_out_tdata.value.integer}')
            received[rx_counter] = dut.m_axis_out_tdata.value.integer
            rx_counter  += 1

        if tb.model.data_valid() and rx_counter_model < num_items:
            received_model[rx_counter_model] = tb.model.get_data()
            # print(f'{rx_counter_model}: rx mod {received_model[rx_counter_model]}')
            rx_counter_model += 1

    ssb_start = np.argmax(received)
    print(f'max model {max(received_model)} max hdl {max(received)}')
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, (ax, ax2) = plt.subplots(2, 1)
        print(f'{type(received.dtype)} {type(received_model.dtype)}')
        ax.plot(np.sqrt(received))
        ax2.plot(np.sqrt(received_model), 'r-')
        ax.axvline(x = ssb_start, color = 'y', linestyle = '--', label = 'axvline - full height')
        plt.show()
    print(f'max correlation is {received[ssb_start]} at {ssb_start}')

    print(f'max model-hdl difference is {max(np.abs(received - received_model))}')
    if tb.ALGO == 0:
        for i in range(len(received)):
            assert received[i] == received_model[i]
    else:
        # TODO: implement model
        pass

    assert ssb_start == 412
    assert len(received) == num_items

# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("ALGO", [0, 1])
@pytest.mark.parametrize("IN_DW", [30, 32])
@pytest.mark.parametrize("OUT_DW", [24, 32])
@pytest.mark.parametrize("TAP_DW", [24, 32])
@pytest.mark.parametrize("CFO", [0, 7500])
@pytest.mark.parametrize("MULT_REUSE", [1, 15, 16])
def test(IN_DW, OUT_DW, TAP_DW, ALGO, CFO, MULT_REUSE):
    dut = 'PSS_correlator_mr'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv')
    ]
    includes = []

    PSS_LEN = 128
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters['OUT_DW'] = OUT_DW
    parameters['TAP_DW'] = TAP_DW
    parameters['PSS_LEN'] = PSS_LEN
    parameters['ALGO'] = ALGO
    parameters['MULT_REUSE'] = MULT_REUSE

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
        force_compile=True
    )

if __name__ == '__main__':
    os.environ['PLOTS'] = "1"
    test(30, 32, 24, 1, 12000, 16)
