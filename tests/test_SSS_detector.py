import numpy as np
import os
import pytest
import logging
import os

import cocotb
import cocotb_test.simulator
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import py3gpp

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

    SSS_len = 127
    N_id_1 = int(os.environ['N_ID_1'])
    N_id_2 = int(os.environ['N_ID_2'])
    print(f'test N_id_1 = {N_id_1}  N_id_2 = {N_id_2}')
    SSS_seq = (py3gpp.nrSSS(3*N_id_1 + N_id_2) + 1) / 2
    # SSS_seq = np.append(SSS_seq, 0)

    await RisingEdge(dut.clk_i)
    dut.N_id_2_i.value = N_id_2
    dut.N_id_2_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.N_id_2_valid_i.value = 0

    for i in range(SSS_len):
        dut.s_axis_in_tvalid.value = 1
        dut.s_axis_in_tdata.value = int(SSS_seq[i])
        await RisingEdge(dut.clk_i)
    dut.s_axis_in_tvalid.value = 0
    await RisingEdge(dut.clk_i)

    max_wait_cycles = 335 * SSS_len + 1000
    cycle_counter = 0
    while cycle_counter < max_wait_cycles:
        await RisingEdge(dut.clk_i)
        if dut.m_axis_out_tvalid.value.integer == 1:
            detected_N_id_1 = dut.m_axis_out_tdata.value.integer
            detected_N_id = dut.N_id_o.value.integer
            print(f'detected_N_id_1 = {detected_N_id_1}')
            break
        cycle_counter += 1

    assert detected_N_id_1 == N_id_1
    assert detected_N_id == N_id_1 * 3 + N_id_2
    # assert dut.m_axis_out_tdata.value == N_id_1

@pytest.mark.parametrize("N_ID_1", [0, 335])
@pytest.mark.parametrize("N_ID_2", [0, 1, 2])
def test(N_ID_1, N_ID_2):
    dut = 'SSS_detector'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'LFSR/LFSR.sv')
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
    test(N_ID_1 = 335, N_ID_2 = 1)
