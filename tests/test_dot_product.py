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
        self.A_DW = int(dut.A_DW.value)
        self.B_DW = int(dut.B_DW.value)
        self.OUT_DW = int(dut.OUT_DW.value)
        self.LEN_DW = int(dut.LEN.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        tests_dir = os.path.abspath(os.path.dirname(__file__))
        #model_dir = os.path.abspath(os.path.join(tests_dir, '../model/PSS_correlator.py'))
        #spec = importlib.util.spec_from_file_location('PSS_correlator', model_dir)
        #foo = importlib.util.module_from_spec(spec)
        #spec.loader.exec_module(foo)
        #self.model = foo.Model(self.IN_DW, self.OUT_DW, self.TAP_DW, self.PSS_LEN, self.PSS_LOCAL, self.ALGO)

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())
        cocotb.start_soon(self.model_clk(CLK_PERIOD_NS, 'ns'))

    async def model_clk(self, period, period_units):
        timer = Timer(period, period_units)
        while True:
            #self.model.tick()
            await timer

    async def cycle_reset(self):
        self.dut.reset_ni.setimmediatevalue(1)
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 0
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 1
        await RisingEdge(self.dut.clk_i)
        # self.model.reset()

    async def send_vector(self, vec_a, vec_b):
        for i in range(len(vec_a)):
            self.dut.start_i.value = i == 0
            self.dut.s_axis_a_tdata.value = int(vec_a[i])
            self.dut.s_axis_b_tdata.value = int(vec_b[i])
            self.dut.s_axis_a_tvalid.value = 1
            self.dut.s_axis_b_tvalid.value = 1
            await RisingEdge(self.dut.clk_i)
        self.dut.s_axis_a_tvalid.value = 0
        self.dut.s_axis_b_tvalid.value = 0
        self.dut.start_i.value = 0
        await RisingEdge(self.dut.clk_i)
        for i in range(10):
            await RisingEdge(self.dut.clk_i)
            if self.dut.valid_o == 1:
                return _twos_comp(self.dut.result_o.value.integer & (2 ** (self.OUT_DW // 2) - 1), self.OUT_DW // 2) \
                    + 1j * _twos_comp((self.dut.result_o.value.integer >> (self.OUT_DW // 2)) & (2 ** (self.OUT_DW // 2) - 1), self.OUT_DW // 2)
        assert False, "no answer received"



@cocotb.test()
async def simple_test(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    for _ in range(10):
        await RisingEdge(dut.clk_i)

    vec_a = np.ones(128)
    vec_b = np.ones(128)
    res = await tb.send_vector(vec_a, vec_b)
    print(f'result = {res}')
    assert res == np.dot(vec_a, vec_b)

    vec_a = np.ones(128)
    vec_b = np.arange(128)
    res = await tb.send_vector(vec_a, vec_b)
    print(f'result = {res}')
    assert res == np.dot(vec_a, vec_b)

    vec_a = np.ones(128)
    vec_b = -np.arange(128)
    vec_b_twos = np.empty(128)
    for i in range(128):
        vec_b_twos[i] = vec_b[i] & (2 ** (tb.B_DW // 2) - 1)
    res = await tb.send_vector(vec_a, vec_b_twos)
    print(f'result = {res}')
    assert res == np.dot(vec_a, vec_b)

    vec_a = np.ones(128)
    vec_b = -np.arange(128)
    vec_b_twos = np.empty(128)
    for i in range(128):
        vec_b_twos[i] = (vec_b[i] & (2 ** (tb.B_DW // 2) - 1)) << (tb.B_DW // 2)
    res = await tb.send_vector(vec_a, vec_b_twos)
    print(f'result = {res}')
    assert res == np.dot(vec_a, 1j * vec_b)


# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("A_DW", [1])
@pytest.mark.parametrize("B_DW", [32])
@pytest.mark.parametrize("LEN", [128])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("A_COMPLEX", [0])
@pytest.mark.parametrize("B_COMPLEX", [1])
def test(A_DW, B_DW, LEN, OUT_DW, A_COMPLEX, B_COMPLEX):
    dut = 'dot_product'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv')
    ]
    includes = []

    parameters = {}
    parameters['A_DW'] = A_DW
    parameters['B_DW'] = B_DW
    parameters['LEN'] = LEN
    parameters['OUT_DW'] = OUT_DW
    parameters['A_COMPLEX'] = A_COMPLEX
    parameters['B_COMPLEX'] = B_COMPLEX
    
    sim_build='sim_build/' + '_'.join(('{}={}'.format(*i) for i in parameters.items()))
    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        includes=includes,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        testcase='simple_test',
        force_compile=True
    )

if __name__ == '__main__':
    test(A_DW = 1, B_DW = 32, LEN = 128, OUT_DW = 32, A_COMPLEX = 0, B_COMPLEX = 1)
