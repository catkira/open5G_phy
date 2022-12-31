import numpy as np
import os
import pytest
import logging
import importlib
#import matplotlib.pyplot as plt

import cocotb
import cocotb_test.simulator
from cocotb.clock import Clock
from cocotb.triggers import Timer
from cocotb.triggers import RisingEdge

#import py3gpp

CLK_PERIOD_NS = 8
CLK_PERIOD_S = CLK_PERIOD_NS * 0.000000001
tests_dir = os.path.abspath(os.path.dirname(__file__))
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', 'hdl'))


class TB(object):
    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        tests_dir = os.path.abspath(os.path.dirname(__file__))
        model_dir = os.path.abspath(os.path.join(tests_dir, "../model/PSS_correlator"))
        spec = importlib.util.spec_from_file_location("PSS_correlator", model_dir)
        foo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(foo)
        self.model = foo.Model() 

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
    await tb.cycle_reset()

    num_items = 100
    i = 0
    while i < num_items:
        await RisingEdge(dut.clk_i)
        dut.s_axis_in_tdata.value = 1 + (2<<16)
        dut.s_axis_in_tvalid.value = 1

        if dut.m_axis_out_tvalid == 1:
            print(dut.m_axis_out_tdata.value.integer)
        i  += 1

def test():
    dut = 'PSS_correlator'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv')
    ]
    includes = []

    PSS_LEN = 127
    parameters = {}
    parameters['IN_DW'] = 32
    parameters['OUT_DW'] = 16
    parameters['PSS_LEN'] = PSS_LEN

    # imaginary part is in upper 16 Bit
    #py3gpp.nrPSS(2)
    taps = np.zeros(10, 'complex')
#    taps = np.fft.ifft(py3gpp.nrPSS(2)) * np.sqrt(PSS_LEN) * 2**15
    #taps[0] = 1 + 1j*10
    #taps[1] = 2 + 1j*20
    parameters['PSS_LOCAL'] = 0
    for i in range(len(taps)):
        parameters['PSS_LOCAL'] += (np.imag(taps[i]).astype(int) << (32*i + 16)) + (np.real(taps[i]).astype(int)<<32*i)

    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}
    sim_build='sim_build/' + '_'.join(('{}={}'.format(*i) for i in parameters.items()))
    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        includes=includes,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env,
        testcase='simple_test'
    )

if __name__ == '__main__':
    test()
