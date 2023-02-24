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
        self.INPUT_WIDTH = int(dut.INPUT_WIDTH.value)
        self.OUTPUT_WIDTH = int(dut.OUTPUT_WIDTH.value)

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

    max_rx_cnt = 500
    MAX_VAL = 2**(tb.INPUT_WIDTH - 1) - 1
    np.random.seed(1)
    numerator = np.random.randint(-MAX_VAL, MAX_VAL, max_rx_cnt)
    denominator = np.random.randint(-MAX_VAL, MAX_VAL, max_rx_cnt)
    tx_cnt = 0
    expected_results = []
    dut.numerator_i.value = int(numerator[tx_cnt])
    dut.denominator_i.value = int(denominator[tx_cnt])
    dut.valid_i.value = 1

    await RisingEdge(dut.clk_i)
    dut.valid_i.value = 0
    tx_cnt += 1
    expected_results.append(np.arctan2(numerator[tx_cnt], denominator[tx_cnt]))

    clk_cnt = 0
    max_clk_cnt = 100000
    rx_cnt = 0
    PI = 2 ** (tb.OUTPUT_WIDTH - 1) - 1

    if os.environ['PIPELINED'] == '0':
        while (clk_cnt < max_clk_cnt) and (rx_cnt < max_rx_cnt):
            await RisingEdge(dut.clk_i)
            clk_cnt += 1

            if (dut.valid_o.value == 1):
                result = _twos_comp(dut.angle_o.value.integer, tb.OUTPUT_WIDTH) / PI * 180
                print(f'atan2({numerator[rx_cnt]} / {denominator[rx_cnt]}) = {result:.3f}  expected {np.arctan2(numerator[rx_cnt], denominator[rx_cnt]) / np.pi * 180:.3f}')
                assert np.abs(np.abs(np.arctan2(numerator[rx_cnt], denominator[rx_cnt]) / np.pi * 180) - np.abs(result)) < 0.1
                rx_cnt += 1

                if rx_cnt < max_rx_cnt:
                    dut.numerator_i.value = int(numerator[tx_cnt])
                    dut.denominator_i.value = int(denominator[tx_cnt])
                    dut.valid_i.value = 1
                    tx_cnt += 1
            else:
                dut.valid_i.value = 0
    else:
        while (clk_cnt < max_clk_cnt) and (rx_cnt < max_rx_cnt):
            await RisingEdge(dut.clk_i)
            clk_cnt += 1

            if tx_cnt < max_rx_cnt:
                dut.numerator_i.value = int(numerator[tx_cnt])
                dut.denominator_i.value = int(denominator[tx_cnt])
                dut.valid_i.value = 1
                expected_results.append(np.arctan2(numerator[tx_cnt], denominator[tx_cnt]))
                # print(f'tx atan2({numerator[tx_cnt]} / {denominator[tx_cnt]})  expecting {expected_results[tx_cnt] / np.pi * 180:.3f}')
                tx_cnt += 1
            else:
                dut.valid_i.value = 0

            if (dut.valid_o.value == 1):
                result = _twos_comp(dut.angle_o.value.integer, tb.OUTPUT_WIDTH) / PI * 180
                print(f'atan2({numerator[rx_cnt]} / {denominator[rx_cnt]}) = {result:.3f}  expected {expected_results[rx_cnt] / np.pi * 180:.3f}')
                # assert np.abs(np.abs(result) - np.abs(expected_results[rx_cnt] / np.pi * 180)) < 0.1
                rx_cnt += 1

    if clk_cnt == max_clk_cnt:
        print("no result received!")
    

@pytest.mark.parametrize("INPUT_WIDTH", [16, 32])
@pytest.mark.parametrize("OUTPUT_WIDTH", [16, 32])
@pytest.mark.parametrize("PIPELINED", [0, 1])
def test(INPUT_WIDTH, OUTPUT_WIDTH, PIPELINED):
    dut = 'atan2'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'atan.sv'),
        os.path.join(rtl_dir, 'div.sv')
    ]
    includes = []

    parameters = {}
    parameters['INPUT_WIDTH'] = INPUT_WIDTH
    parameters['OUTPUT_WIDTH'] = OUTPUT_WIDTH
    os.environ['PIPELINED'] = str(PIPELINED)

    parameters_dir = parameters.copy()
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
    test(INPUT_WIDTH = 18, OUTPUT_WIDTH = 16, PIPELINED = 0)
