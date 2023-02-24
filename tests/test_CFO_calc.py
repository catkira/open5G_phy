import numpy as np
import os
import pytest
import logging
import matplotlib.pyplot as plt
import os

import cocotb
import cocotb_test.simulator
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


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
        self.C_DW = int(dut.C_DW.value)
        self.CFO_DW = int(dut.CFO_DW.value)
        self.DDS_DW = int(dut.DDS_DW.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())

    async def cycle_reset(self):
        self.dut.reset_ni.setimmediatevalue(1)
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 0
        await RisingEdge(self.dut.clk_i)
        self.dut.reset_ni.value = 1
        await RisingEdge(self.dut.clk_i)

@cocotb.test()
async def simple_test(dut):
    tb = TB(dut)

    dut.valid_i.value = 0
    await tb.cycle_reset()
    angle = int(os.environ['ANGLE'])
    C0 = 1
    C1 = C0 * np.exp(1j * angle / 180 * np.pi)
    MAX_VAL = int(2 ** (tb.C_DW // 2 - 1) - 1)
    dut.C0_i.value = ((int(C0.imag*MAX_VAL) & int(2**(tb.C_DW//2)-1)) << (tb.C_DW//2)) + (int(C0.real*MAX_VAL) & int(2**(tb.C_DW//2)-1))
    dut.C1_i.value = ((int(C1.imag*MAX_VAL) & int(2**(tb.C_DW//2)-1)) << (tb.C_DW//2)) + (int(C1.real*MAX_VAL) & int(2**(tb.C_DW//2)-1))
    dut.valid_i.value = 1

    await RisingEdge(dut.clk_i)
    dut.valid_i.value = 0
    received_angle = 0

    clk_cnt = 0
    max_clk_cnt = 1000
    while clk_cnt < max_clk_cnt:
        await RisingEdge(dut.clk_i)
        clk_cnt += 1
        if (dut.valid_o.value == 1):
            received_angle = _twos_comp(dut.CFO_angle_o.value.integer, tb.CFO_DW) / (2**(tb.CFO_DW-1) - 1) * 180
            print(f'received CFO {received_angle} deg')
            print(f'expected CFO {angle} deg')
            DDS_inc = _twos_comp(dut.CFO_DDS_inc_o.value.integer, tb.DDS_DW)
            print(f'received DDS inc {DDS_inc}')
            break

    assert np.abs(received_angle + angle) < 1

@pytest.mark.parametrize("C_DW", [30, 32])
@pytest.mark.parametrize("CFO_DW", [20, 32])
@pytest.mark.parametrize("DDS_DW", [20])
@pytest.mark.parametrize("ANGLE", [20, 60, 100, 150, 170, -20, -60, -100, -150, -170])
def test(C_DW, CFO_DW, DDS_DW, ANGLE):
    dut = 'CFO_calc'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'atan.sv'),
        os.path.join(rtl_dir, 'atan2.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'complex_multiplier', 'complex_multiplier.v')
    ]
    includes = []

    parameters = {}
    parameters['C_DW'] = C_DW
    parameters['CFO_DW'] = CFO_DW
    parameters['DDS_DW'] = DDS_DW
    os.environ['ANGLE'] = str(ANGLE)

    parameters_dir = parameters.copy()
    parameters_dir['ANGLE'] = ANGLE
    
    sim_build='sim_build/' + '_'.join(('{}={}'.format(*i) for i in parameters_dir.items()))
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
        waves=True
    )

if __name__ == '__main__':
    test(C_DW = 30, CFO_DW = 32, DDS_DW = 20, ANGLE=80)
