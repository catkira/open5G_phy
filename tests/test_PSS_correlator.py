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
        self.PSS_LEN = int(dut.PSS_LEN.value)
        self.PSS_LOCAL = int(dut.PSS_LOCAL.value)
        self.ALGO = int(dut.ALGO.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        tests_dir = os.path.abspath(os.path.dirname(__file__))
        model_dir = os.path.abspath(os.path.join(tests_dir, '../model/PSS_correlator.py'))
        spec = importlib.util.spec_from_file_location('PSS_correlator', model_dir)
        foo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(foo)
        self.model = foo.Model(self.IN_DW, self.OUT_DW, self.PSS_LEN, self.PSS_LOCAL, self.ALGO) 

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
    handle = sigmf.sigmffile.fromfile('../../tests/30720KSPS_dl_signal.sigmf-data')
    waveform = handle.read_samples()
    waveform /= max(waveform.real.max(), waveform.imag.max())    
    waveform = scipy.signal.decimate(waveform, 16, ftype='fir')
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= 2**15
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)    

    tb = TB(dut)
    await tb.cycle_reset()

    num_items = 500
    rx_counter = 0
    rx_counter_model = 0
    in_counter = 0
    received = np.empty(num_items, int)
    received_model = np.empty(num_items, int)
    while rx_counter < num_items:
        await RisingEdge(dut.clk_i)
        data = (((int(waveform[in_counter].imag)&0xFFFF)<<16) + ((int(waveform[in_counter].real))&0xFFFF))&0xFFFFFFFF
        dut.s_axis_in_tdata.value = data
        dut.s_axis_in_tvalid.value = 1
        tb.model.set_data(data)
        in_counter += 1

        if dut.m_axis_out_tvalid == 1:
            # print(dut.m_axis_out_tdata.value.integer)
            received[rx_counter] = dut.m_axis_out_tdata.value.integer
            # print(f'rx hdl {received[rx_counter]}')
            rx_counter  += 1

        if tb.model.data_valid() and rx_counter_model < num_items:
            received_model[rx_counter_model] = tb.model.get_data()
            # print(f'rx mod {received_model[rx_counter_model]}')
            rx_counter_model += 1

    ssb_start = np.argmax(received)
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, ax = plt.subplots()
        ax.plot(np.sqrt(received))
        ax2=ax.twinx()
        ax2.plot(np.sqrt(received_model), 'r-')
        ax.axvline(x = ssb_start, color = 'y', linestyle = '--', label = 'axvline - full height')
        plt.show()
    print(f'max correlation is {received[ssb_start]} at {ssb_start}')

    ok_limit = 100 if tb.dut.ALGO else 0.001 # model is currently only bit exact for ALGO=0
    for i in range(len(received)):
        assert np.abs((received[i]-received_model[i])/received_model[i]) < ok_limit

    assert ssb_start == 411
    assert len(received) == num_items

@pytest.mark.parametrize("ALGO", [0, 1])
def test(ALGO):
    dut = 'PSS_correlator'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv')
    ]
    includes = []

    PSS_LEN = 128
    parameters = {}
    parameters['IN_DW'] = 32
    parameters['OUT_DW'] = 32
    parameters['PSS_LEN'] = PSS_LEN
    parameters['ALGO'] = ALGO

    # imaginary part is in upper 16 Bit
    PSS = np.zeros(PSS_LEN, 'complex')
    PSS[0:-1] = py3gpp.nrPSS(2)
    taps = np.fft.ifft(np.fft.fftshift(PSS))
    taps /= max(taps.real.max(), taps.imag.max())
    taps *= 2**15
    # for i in range(10):
    #     print(f'taps[{i}] = {taps[i]}')
    #taps = taps[1:] # remove first tap to make taps symmetric
    parameters['PSS_LOCAL'] = 0
    for i in range(len(taps)):
        parameters['PSS_LOCAL'] += ((int(np.round(np.imag(taps[i])))&0xFFFF) << (32*i + 16)) + ((int(np.round(np.real(taps[i])))&0xFFFF) << (32*i))
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
        force_compile=True
    )

if __name__ == '__main__':
    test()
