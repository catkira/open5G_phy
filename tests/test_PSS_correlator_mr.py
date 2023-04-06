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
        self.IN_DW = int(dut.IN_DW.value)
        self.OUT_DW = int(dut.OUT_DW.value)
        self.TAP_DW = int(dut.TAP_DW.value)
        self.PSS_LEN = int(dut.PSS_LEN.value)
        self.PSS_LOCAL = int(dut.PSS_LOCAL.value)
        self.MULT_REUSE = int(dut.MULT_REUSE.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        tests_dir = os.path.abspath(os.path.dirname(__file__))
        model_dir = os.path.abspath(os.path.join(tests_dir, '../model/PSS_correlator.py'))
        spec = importlib.util.spec_from_file_location('PSS_correlator', model_dir)
        foo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(foo)
        self.model = foo.Model(self.IN_DW, self.OUT_DW, self.TAP_DW, self.PSS_LEN, self.PSS_LOCAL, ALGO = 0)

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
    decimation_factor = 16
    waveform = scipy.signal.decimate(waveform, decimation_factor, ftype='fir')
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= 2 ** (tb.IN_DW // 2 - 1) - 1
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)
    await tb.cycle_reset()

    num_items = 500
    rx_cnt = 0
    rx_cnt_model = 0
    tx_cnt = 0
    received = np.empty(num_items, int)
    received_model = np.empty(num_items, int)
    clk_div = 0
    clk_decimation = 16
    C0 = []
    C1 = []
    C_DW = int(tb.IN_DW + tb.TAP_DW + 2 + 2*np.ceil(np.log2(tb.PSS_LEN)))
    while rx_cnt < num_items:
        await RisingEdge(dut.clk_i)
        if clk_div < (clk_decimation - 1):
            dut.s_axis_in_tvalid.value = 0
            clk_div += 1
        else:
            clk_div = 0
            data = (((int(waveform[tx_cnt].imag)  & (2 ** (tb.IN_DW // 2) - 1)) << (tb.IN_DW // 2)) \
                  + ((int(waveform[tx_cnt].real)) & (2 ** (tb.IN_DW // 2) - 1))) & (2 ** tb.IN_DW - 1)
            dut.s_axis_in_tdata.value = data
            dut.s_axis_in_tvalid.value = 1
            tb.model.set_data(data)
            tx_cnt += 1

        if dut.m_axis_out_tvalid == 1:
            # print(f'{rx_counter}: rx hdl {dut.m_axis_out_tdata.value}')
            received[rx_cnt] = dut.m_axis_out_tdata.value.integer
            C0.append(_twos_comp(dut.C0_o.value.integer & (2 ** (C_DW // 2) - 1),C_DW // 2) \
                    + 1j * _twos_comp((dut.C0_o.value.integer >> (C_DW // 2)) & (2 ** (C_DW // 2) - 1), C_DW // 2))
            C1.append(_twos_comp(dut.C1_o.value.integer & (2 ** (C_DW // 2) - 1), C_DW // 2) \
                    + 1j * _twos_comp((dut.C1_o.value.integer >> (C_DW // 2)) & (2 ** (C_DW // 2) - 1), C_DW // 2))
            rx_cnt  += 1

        if tb.model.data_valid() and rx_cnt_model < num_items:
            received_model[rx_cnt_model] = tb.model.get_data()
            # print(f'{rx_counter_model}: rx mod {received_model[rx_counter_model]}')
            rx_cnt_model += 1

    ssb_start = np.argmax(received) - 128
    received = np.array(received)[128:]
    received_model = np.array(received_model)[128:]
    print(f'max model {max(received_model)} max hdl {max(received)}')
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        _, (ax, ax2) = plt.subplots(2, 1)
        print(f'{type(received.dtype)} {type(received_model.dtype)}')
        ax.plot(np.sqrt(received))
        ax.set_title('hdl')
        ax2.plot(np.sqrt(received_model), 'r-')
        ax2.set_title('model')
        ax.axvline(x = ssb_start, color = 'y', linestyle = '--', label = 'axvline - full height')
        plt.show()
    print(f'max correlation is {received[ssb_start]} at {ssb_start}')

    print(f'max model-hdl difference is {max(np.abs(received - received_model))}')
    for i in range(len(received)):
        assert received[i] == received_model[i]

    prod = C0[ssb_start+128] * np.conj(C1[ssb_start+128])
    # detectedCFO = np.arctan2(prod.imag, prod.real)
    detectedCFO = np.angle(prod)
    detectedCFO_Hz = detectedCFO / (2*np.pi) * (fs/decimation_factor) / 64
    print(f'detected CFO = {detectedCFO_Hz} Hz')

    PSS = np.zeros(128, 'complex')
    PSS[:-1] = py3gpp.nrPSS(2)
    taps = np.fft.ifft(np.fft.fftshift(PSS))
    C0 = np.vdot(waveform[ssb_start:][:64], taps[:64])
    C1 = np.vdot(waveform[ssb_start+64:][:64], taps[64:][:64])
    prod = C0 * np.conj(C1)
    # detectedCFO = np.arctan2(prod.imag, prod.real)
    detectedCFO = np.angle(prod)
    detectedCFO_Hz_model = detectedCFO / (2*np.pi) * (fs/decimation_factor) / 64
    print(f'detected CFO (model) = {detectedCFO_Hz_model} Hz')
    if CFO != 0:
        assert (np.abs(detectedCFO_Hz - detectedCFO_Hz_model)/np.abs(CFO)) < 0.05
    else:
        assert np.abs(detectedCFO_Hz - detectedCFO_Hz_model) < 20

    assert ssb_start == 284
    assert len(received) == num_items - 128


@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [45])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("CFO", [0, 6500, -5500])
@pytest.mark.parametrize("MULT_REUSE", [1, 16])
def test_CFO(IN_DW, OUT_DW, TAP_DW, CFO, MULT_REUSE):
    test(IN_DW, OUT_DW, TAP_DW, CFO, MULT_REUSE)

# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("IN_DW", [14, 32])
@pytest.mark.parametrize("OUT_DW", [45])
@pytest.mark.parametrize("TAP_DW", [18, 32])
@pytest.mark.parametrize("CFO", [1000])
@pytest.mark.parametrize("MULT_REUSE", [1, 15, 16])
def test(IN_DW, OUT_DW, TAP_DW, CFO, MULT_REUSE):
    dut = 'PSS_correlator_mr'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'complex_multiplier', 'complex_multiplier.v')
    ]
    includes = []

    PSS_LEN = 128
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters['OUT_DW'] = OUT_DW
    parameters['TAP_DW'] = TAP_DW
    parameters['PSS_LEN'] = PSS_LEN
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
    parameters_dirname = parameters.copy()
    del parameters_dirname['PSS_LOCAL']
    parameters_dirname['CFO'] = CFO
    sim_build='sim_build/' + '_'.join(('{}={}'.format(*i) for i in parameters_dirname.items()))
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
        force_compile=True,
        waves=True
    )

if __name__ == '__main__':
    os.environ['PLOTS'] = "1"
    test(IN_DW = 32, OUT_DW = 45, TAP_DW = 18, CFO = 2000, MULT_REUSE = 16)
