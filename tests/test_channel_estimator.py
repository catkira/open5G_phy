import numpy as np
import os
import pytest
import logging
import os
import scipy
import matplotlib.pyplot as plt

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

class TB(object):
    def __init__(self, dut):
        self.dut = dut

        self.IN_DW = int(dut.IN_DW.value)

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
    N_id = N_id_1 * 3 + N_id_2
    print(f'test N_id_1 = {N_id_1}  N_id_2 = {N_id_2} -> N_id = {N_id}')

    await RisingEdge(dut.clk_i)
    dut.N_id_i.value = N_id
    dut.N_id_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.N_id_valid_i.value = 0

    max_wait_cycles = 3000
    cycle_counter = 0
    PBCH_DMRS = []
    ibar_SSB = 2
    PBCH_DMRS_model = py3gpp.nrPBCHDMRS(N_id, ibar_SSB)*np.sqrt(2)
    while cycle_counter < max_wait_cycles:
        await RisingEdge(dut.clk_i)
        if dut.debug_PBCH_DMRS_valid_o.value == 1:
            PBCH_DMRS.append(1j*(1-2*(dut.debug_PBCH_DMRS_o.value % 2)) + (1-2*((dut.debug_PBCH_DMRS_o.value >> 1) % 2)))
            # print(f'PBCH_DMRS[{len(PBCH_DMRS)-1}] = {PBCH_DMRS[len(PBCH_DMRS)-1]}  <->  {PBCH_DMRS_model[len(PBCH_DMRS)-1]}')
            assert PBCH_DMRS[len(PBCH_DMRS)-1] == PBCH_DMRS_model[len(PBCH_DMRS)-1]
        cycle_counter += 1
    
@cocotb.test()
async def simple_test2(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    N_id_1 = 69
    N_id_2 = 2
    N_id = N_id_1 * 3 + N_id_2
    print(f'test N_id_1 = {N_id_1}  N_id_2 = {N_id_2} -> N_id = {N_id}')

    await RisingEdge(dut.clk_i)
    dut.N_id_i.value = N_id
    dut.N_id_valid_i.value = 1
    await RisingEdge(dut.clk_i)
    dut.N_id_valid_i.value = 0

    handle = sigmf.sigmffile.fromfile(tests_dir + '/30720KSPS_dl_signal.sigmf-data')
    waveform = handle.read_samples()
    # waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform = scipy.signal.decimate(waveform, 16//2, ftype='fir')  # decimate to 3.840 MSPS
    # waveform /= max(waveform.real.max(), waveform.imag.max())
    # waveform *= (2 ** (tb.IN_DW // 2 - 1) - 1)
    # waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)
    CP_LEN = 18
    FFT_LEN = 256
    START_POS = 842  # ibar_SSB is 0 for this SSB
    ibar_SSB = 2
    PBCH = np.fft.fftshift(np.fft.fft(waveform[START_POS:][:FFT_LEN]))
    PBCH = np.append(PBCH, np.fft.fftshift(np.fft.fft(waveform[START_POS + CP_LEN + FFT_LEN:][:FFT_LEN])))
    PBCH = np.append(PBCH, np.fft.fftshift(np.fft.fft(waveform[START_POS + 2 * (CP_LEN + FFT_LEN):][:FFT_LEN])))

    PBCH /= max(PBCH.real.max(), PBCH.imag.max())
    PBCH *= (2 ** (tb.IN_DW // 2 - 1) - 1)
    PBCH = PBCH.real.astype(int) + 1j*PBCH.imag.astype(int)

    # plt.plot(PBCH[8:248].real, PBCH[8:248].imag, '.r')
    # plt.show()

    max_wait_cycles = 15000
    cycle_counter = 0
    PBCH_DMRS = []
    PBCH_DMRS_model = py3gpp.nrPBCHDMRS(N_id, ibar_SSB)*np.sqrt(2)
    PBCH_cnt = 0
    while cycle_counter < max_wait_cycles:
        await RisingEdge(dut.clk_i)
        if dut.debug_PBCH_DMRS_valid_o.value == 1:
            PBCH_DMRS.append(1j*(1-2*(dut.debug_PBCH_DMRS_o.value % 2)) + (1-2*((dut.debug_PBCH_DMRS_o.value >> 1) % 2)))
            # print(f'PBCH_DMRS[{len(PBCH_DMRS)-1}] = {PBCH_DMRS[len(PBCH_DMRS)-1]}  <->  {PBCH_DMRS_model[len(PBCH_DMRS)-1]}')
            assert PBCH_DMRS[len(PBCH_DMRS)-1] == PBCH_DMRS_model[len(PBCH_DMRS)-1]

        if cycle_counter > 2000 and PBCH_cnt < 256*3:
            data = (((int(PBCH[PBCH_cnt].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
                  + ((int(PBCH[PBCH_cnt].real)) & ((2 ** (tb.IN_DW // 2)) - 1)))
            dut.s_axis_in_tdata.value = data
            dut.s_axis_in_tvalid.value = 1
            dut.PBCH_start_i.value = PBCH_cnt == 0
            PBCH_cnt += 1
        else:
            dut.s_axis_in_tvalid.value = 0

        if dut.debug_ibar_SSB_valid_o.value == 1:
            ibar_SSB_det = dut.debug_ibar_SSB_o.value.integer
            print(f'detected ibar_SSB = {ibar_SSB_det}')
            assert ibar_SSB_det == 0
        cycle_counter += 1

@pytest.mark.parametrize("N_ID_1", [0, 335])
@pytest.mark.parametrize("N_ID_2", [0, 1, 2])
def test_PBCH_DMRS_gen(N_ID_1, N_ID_2):
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

@pytest.mark.parametrize("IN_DW", [32])
def test_PBCH_ibar_SSB_det(IN_DW):
    dut = 'channel_estimator'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'LFSR/LFSR.sv'),
        os.path.join(rtl_dir, 'complex_multiplier/complex_multiplier.v')
    ]
    includes = []

    parameters = {}
    parameters['IN_DW'] = IN_DW

    sim_build='sim_build/' + '_'.join(('{}={}'.format(*i) for i in parameters.items()))
    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        includes=includes,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        testcase='simple_test2',
        force_compile=True
    )

if __name__ == '__main__':
    # test_PBCH_DMRS_gen(N_ID_1 = 69, N_ID_2 = 2)
    test_PBCH_ibar_SSB_det(IN_DW = 32)
