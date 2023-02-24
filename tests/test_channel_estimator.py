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
    waveform = scipy.signal.decimate(waveform, 8, ftype='fir')  # decimate to 3.840 MSPS

    CP_LEN = 18
    FFT_LEN = 256
    ibar_SSB = int(os.environ['ibar_SSB'])
    START_POS = 842 + int(3.84e6 * 0.001 * int(ibar_SSB / 2)) + 1646 * (ibar_SSB % 2)   # this hack works for ibar_SSB = 0 .. 3
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
    PBCH_cnt = 0
    while cycle_counter < max_wait_cycles:
        await RisingEdge(dut.clk_i)

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
            assert ibar_SSB_det == ibar_SSB
        cycle_counter += 1

@cocotb.test()
async def simple_test3(dut):
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
    waveform = scipy.signal.decimate(waveform, 8, ftype='fir')  # decimate to 3.840 MSPS

    CP1_LEN = 20
    CP2_LEN = 18
    FFT_LEN = 256
    L_MAX = 4 # 4 SSBs
    SSB_pattern = [2, 8, 16, 22]  # case A

    START_POS = 842  #+ int(3.84e6 * 0.001 * int(ibar_SSB / 2)) + 1646 * (ibar_SSB % 2)   # this hack works for ibar_SSB = 0 .. 3
    START_SYMBOL = 2
    num_symbols = 50
    symbol = np.empty((num_symbols,256), 'complex')

    pos = START_POS
    if os.environ.get('PLOTS') == '1':
        _, axs = plt.subplots(8, 7, sharex=True, sharey=True)
        axs = np.ravel(axs)
    for i in range(num_symbols):
        new_symbol = np.fft.fftshift(np.fft.fft(waveform[pos:][:FFT_LEN]))
        if (i+4)%7 == 0:
            pos += CP1_LEN + FFT_LEN
        else:
            pos += CP2_LEN + FFT_LEN
        if os.environ.get('PLOTS') == '1':
            axs[i].plot(new_symbol.real, new_symbol.imag, '.r')
        symbol[i] = new_symbol
    if os.environ.get('PLOTS') == '1':
        plt.show()

    symbol /= max(symbol.real.max(), symbol.imag.max())
    symbol *= (2 ** (tb.IN_DW // 2 - 1) - 1)
    symbol = symbol.real.astype(int) + 1j*symbol.imag.astype(int)

    max_wait_cycles = 100000
    clk_cnt = 0
    symbol_id = 0
    SC_cnt = 0
    ibar_SSB = 0
    IQ_data = []
    while clk_cnt < max_wait_cycles:
        await RisingEdge(dut.clk_i)

        # need to wait until the PBCH_DMRS is generated
        if (clk_cnt > 2000) and (symbol_id < num_symbols):
            if ((symbol_id + START_SYMBOL) in SSB_pattern) and (SC_cnt == 0):
                dut.PBCH_start_i.value = 1
            else:
                dut.PBCH_start_i.value = 0
            if SC_cnt == 0:
                print(f'sending symbol {symbol_id}')

            data = (((int(symbol[symbol_id][SC_cnt].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
                + ((int(symbol[symbol_id][SC_cnt].real)) & ((2 ** (tb.IN_DW // 2)) - 1)))
            dut.s_axis_in_tdata.value = data
            dut.s_axis_in_tvalid.value = 1
            if dut.s_axis_in_tvalid.value and ((symbol_id + START_SYMBOL) in SSB_pattern):
                IQ_data.append(symbol[symbol_id][SC_cnt])

            SC_cnt += 1
            if SC_cnt == 256:
                symbol_id += 1
                SC_cnt = 0

        else:
            dut.s_axis_in_tvalid.value = 0

        if dut.debug_ibar_SSB_valid_o.value == 1:
            ibar_SSB_det = dut.debug_ibar_SSB_o.value.integer
            print(f'detected ibar_SSB = {ibar_SSB_det}')
            assert ibar_SSB_det == ibar_SSB
            ibar_SSB += 1
        clk_cnt += 1
    print(f'finished after {clk_cnt} clk cycles')

    if os.environ.get('PLOTS') == '1':
        IQ_data = np.array(IQ_data)
        plt.plot(IQ_data.real[8:200], IQ_data.imag[8:200], '.')
        plt.show()

@pytest.mark.parametrize("N_ID_1", [0, 335])
@pytest.mark.parametrize("N_ID_2", [0, 1, 2])
def test_PBCH_DMRS_gen(N_ID_1, N_ID_2):
    dut = 'channel_estimator'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'LFSR/LFSR.sv'),
        os.path.join(rtl_dir, 'complex_multiplier/complex_multiplier.v')
    ]
    includes = []

    os.environ['N_ID_1'] = str(N_ID_1)
    os.environ['N_ID_2'] = str(N_ID_2)
    parameters = {}
    parameters_dirname = parameters.copy()
    parameters_dirname['N_ID_1'] = str(N_ID_1)
    parameters_dirname['N_ID_2'] = str(N_ID_2)

    sim_build='sim_build/test' + '_'.join(('{}={}'.format(*i) for i in parameters_dirname.items()))
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

@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("ibar_SSB", [0, 1, 2, 3])
def test_PBCH_ibar_SSB_det(IN_DW, ibar_SSB):
    dut = 'channel_estimator'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'LFSR/LFSR.sv'),
        os.path.join(rtl_dir, 'complex_multiplier/complex_multiplier.v')
    ]
    includes = []
    os.environ['ibar_SSB'] = str(ibar_SSB)
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters_dirname = parameters.copy()
    parameters_dirname['ibar_SSB'] = str(ibar_SSB)

    sim_build='sim_build/test2' + '_'.join(('{}={}'.format(*i) for i in parameters_dirname.items()))
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

@pytest.mark.parametrize("IN_DW", [32])
def test_PBCH_stream(IN_DW):
    dut = 'channel_estimator'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'div.sv'),
        os.path.join(rtl_dir, 'atan.sv'),
        os.path.join(rtl_dir, 'atan2.sv'),
        os.path.join(rtl_dir, 'AXIS_FIFO.sv'),
        os.path.join(rtl_dir, 'LFSR/LFSR.sv'),
        os.path.join(rtl_dir, 'complex_multiplier/complex_multiplier.v')
    ]
    includes = []
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters_dirname = parameters.copy()

    sim_build='sim_build/test3' + '_'.join(('{}={}'.format(*i) for i in parameters_dirname.items()))
    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        includes=includes,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        testcase='simple_test3',
        force_compile=True,
        waves=True
    )


if __name__ == '__main__':
    # test_PBCH_DMRS_gen(N_ID_1 = 69, N_ID_2 = 2)
    # test_PBCH_ibar_SSB_det(IN_DW = 32, ibar_SSB = 3)
    # os.environ['PLOTS'] = '1'
    test_PBCH_stream(IN_DW = 32)
