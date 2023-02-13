import numpy as np
import os
import pytest
import logging
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

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

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
    await tb.cycle_reset()

    N_id_1 = int(os.environ['N_ID_1'])
    N_id_2 = int(os.environ['N_ID_2'])
    print(f'test N_id_1 = {N_id_1}  N_id_2 = {N_id_2} -> N_id = {N_id_1 * 3 + N_id_2}')

    await RisingEdge(dut.clk_i)
    dut.N_id_i.value = N_id_1 * 3 + N_id_2
    dut.N_id_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.N_id_valid_i.value = 0

    max_wait_cycles = 2000
    cycle_counter = 0
    PBCH_DMRS = []
    while cycle_counter < max_wait_cycles:
        await RisingEdge(dut.clk_i)
        if dut.debug_PBCH_DMRS_valid_o.value == 1:
            PBCH_DMRS.append((dut.debug_PBCH_DMRS_o.value % 2) + 1j*((dut.debug_PBCH_DMRS_o.value >> 1) % 2))
            print(f'PBCH_DMRS[{len(PBCH_DMRS)-1}] = {PBCH_DMRS[len(PBCH_DMRS)-1]}')
        cycle_counter += 1
    

@pytest.mark.parametrize("N_ID_1", [0, 335])
@pytest.mark.parametrize("N_ID_2", [0, 1, 2])
def test(N_ID_1, N_ID_2):
    dut = 'channel_estimator'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'LFSR/LFSR.sv'),
        os.path.join(rtl_dir, 'complex_multiplier/complex_multiplier.v')
    ]
    includes = []

    os.environ['N_ID_1'] = str(N_ID_1)
    os.environ['N_ID_2'] = str(N_ID_2)
    parameters = {}

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
    test(N_ID_1 = 69, N_ID_2 = 1)
