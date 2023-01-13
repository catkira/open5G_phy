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
        self.ALGO = int(dut.ALGO.value)
        self.WINDOW_LEN = int(dut.WINDOW_LEN.value)

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        tests_dir = os.path.abspath(os.path.dirname(__file__))
        model_file = os.path.abspath(os.path.join(tests_dir, '../model/PSS_correlator.py'))
        spec = importlib.util.spec_from_file_location('PSS_correlator', model_file)
        foo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(foo)
        self.PSS_correlator_model = foo.Model(self.IN_DW, self.OUT_DW, self.TAP_DW, self.PSS_LEN, self.PSS_LOCAL, self.ALGO) 

        model_file = os.path.abspath(os.path.join(tests_dir, '../model/peak_detector.py'))
        spec = importlib.util.spec_from_file_location('peak_detector', model_file)
        foo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(foo)
        self.peak_detector_model = foo.Model(self.OUT_DW, self.WINDOW_LEN)

        cocotb.start_soon(Clock(self.dut.clk_i, CLK_PERIOD_NS, units='ns').start())
        cocotb.start_soon(self.model_clk(CLK_PERIOD_NS, 'ns'))

    async def model_clk(self, period, period_units):
        timer = Timer(period, period_units)
        while True:
            self.PSS_correlator_model.tick()
            self.peak_detector_model.tick()
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
        self.PSS_correlator_model.reset()
        self.peak_detector_model.reset()

@cocotb.test()
async def simple_test(dut):
    handle = sigmf.sigmffile.fromfile('../../tests/30720KSPS_dl_signal.sigmf-data')
    waveform = handle.read_samples()
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform = scipy.signal.decimate(waveform, 16//2, ftype='fir')  # decimate to 3.840 MSPS
    waveform /= max(waveform.real.max(), waveform.imag.max())
    waveform *= 2**15
    waveform = waveform.real.astype(int) + 1j*waveform.imag.astype(int)

    tb = TB(dut)
    await tb.cycle_reset()

    num_items = 2000
    rx_counter = 0
    rx_counter_model = 0
    in_counter = 0
    received = np.empty(num_items, int)
    received_correlator = []
    received_model = np.empty(num_items, int)
    received_fft = []
    received_fft_ideal = []
    fft_started = False
    wait_cycles = 0
    SSS_delay = 256 + 2*9 - 5
    while rx_counter < num_items:
        await RisingEdge(dut.clk_i)
        data = (((int(waveform[in_counter].imag)  & ((2 ** (tb.IN_DW // 2)) - 1)) << (tb.IN_DW // 2)) \
              + ((int(waveform[in_counter].real)) & ((2 ** (tb.IN_DW // 2)) - 1))) & ((2 ** tb.IN_DW) - 1)
        dut.s_axis_in_tdata.value = data
        dut.s_axis_in_tvalid.value = 1
        tb.PSS_correlator_model.set_data(data)
        in_counter += 1

        # print(f'{dut.m_axis_cic_tvalid.value.integer} + {dut.m_axis_cic_tdata.value.integer}')

        if dut.m_axis_correlator_debug_tvalid == 1:
            received_correlator.append(dut.m_axis_correlator_debug_tdata.value.integer)

        #if dut.m_axis_out_tvalid == 1:
            # print(dut.m_axis_out_tdata.value.integer)
         #   received[rx_counter] = dut.m_axis_out_tdata.value.integer
            # print(f'rx hdl {received[rx_counter]}')
          #  rx_counter  += 1
        received[rx_counter] = dut.peak_detected_debug_o.value.integer
        rx_counter += 1
        # print(dut.peak_detected_o.value.integer)

        # if tb.model.data_valid() and rx_counter_model < num_items:
        #     received_model[rx_counter_model] = tb.model.get_data()
        #     # print(f'rx mod {received_model[rx_counter_model]}')
        #     rx_counter_model += 1

        
        if dut.fft_sync_debug_o == 1:
            print('start FFT')
            print(f'fft_sync_debug_o {dut.fft_sync_debug_o}')
            fft_started = True

        if dut.peak_detected_debug_o.value.integer == 1 or wait_cycles > 0:
            if wait_cycles < SSS_delay:
                wait_cycles += 1
            elif len(received_fft_ideal) < 256:
                received_fft_ideal.append(waveform[in_counter])

        if len(received_fft) == 256 and fft_started:
            print('end fft')
            fft_started = False
        
        print(f'fft_sync_debug_o {dut.fft_sync_debug_o}')
        if fft_started and (len(received_fft) < 256):
            print(f'fft_result_debug_o {dut.fft_result_debug_o}')
            received_fft.append(1j*_twos_comp(dut.fft_result_debug_o.value.integer & (2**19 - 1), 19)
                + _twos_comp((dut.fft_result_debug_o.value.integer>>19) & (2**19 - 1), 19))

    peak_pos = np.argmax(received)
    if 'PLOTS' in os.environ and os.environ['PLOTS'] == '1':
        ax1 = plt.subplot(4, 2, 1)
        ax1.plot(np.abs(np.fft.fftshift(np.fft.fft(received_fft_ideal))))
        ax = plt.subplot(4, 2, 2)
        ax.plot(np.real(np.fft.fftshift(np.fft.fft(received_fft_ideal))[63:][:128]),
            np.imag(np.fft.fftshift(np.fft.fft(received_fft_ideal))[63:][:128]), '.')

        ax2 = plt.subplot(4, 2, 3)
        ax2.plot(np.abs(np.fft.fftshift(received_fft)))
        ax3 = plt.subplot(4, 2, 5)
        ax3.plot(np.abs(np.fft.fftshift(received_fft)[64:][:128]))
        ax4 = plt.subplot(4, 2, 7)
        ax4.plot(np.real(np.fft.fftshift(received_fft)[64:][:128]), 'r-')
        ax42 = ax4.twinx()
        ax42.plot(np.imag(np.fft.fftshift(received_fft)[64:][:128]), 'b-')
        ax5 = plt.subplot(4, 2, 8)
        ax5.plot(np.real(np.fft.fftshift(received_fft)[64:][:128]), np.imag(np.fft.fftshift(received_fft)[64:][:128]), '.')
        plt.show()

    print(f'highest peak at {peak_pos}')
    assert peak_pos == 838
    assert False


# bit growth inside PSS_correlator is a lot, be careful to not make OUT_DW too small !
@pytest.mark.parametrize("ALGO", [0, 1])
@pytest.mark.parametrize("IN_DW", [32])
@pytest.mark.parametrize("OUT_DW", [32])
@pytest.mark.parametrize("TAP_DW", [32])
@pytest.mark.parametrize("WINDOW_LEN", [8])
def test(IN_DW, OUT_DW, TAP_DW, ALGO, WINDOW_LEN):
    dut = 'Decimator_Correlator_PeakDetector_FFT'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f'{dut}.sv'),
        os.path.join(rtl_dir, 'Peak_detector.sv'),
        os.path.join(rtl_dir, 'PSS_correlator.sv'),
        os.path.join(rtl_dir, 'CIC/cic_d.sv'),
        os.path.join(rtl_dir, 'CIC/comb.sv'),
        os.path.join(rtl_dir, 'CIC/downsampler.sv'),
        os.path.join(rtl_dir, 'CIC/integrator.sv'),
        os.path.join(rtl_dir, 'fft-core/bimpy.v'),
        os.path.join(rtl_dir, 'fft-core/bitreverse.v'),
        os.path.join(rtl_dir, 'fft-core/butterfly.v'),
        os.path.join(rtl_dir, 'fft-core/convround.v'),
        os.path.join(rtl_dir, 'fft-core/fftmain.v'),
        os.path.join(rtl_dir, 'fft-core/fftstage.v'),
        os.path.join(rtl_dir, 'fft-core/hwbfly.v'),
        os.path.join(rtl_dir, 'fft-core/laststage.v'),
        os.path.join(rtl_dir, 'fft-core/longbimpy.v'),
        os.path.join(rtl_dir, 'fft-core/qtrstage.v')
    ]
    includes = [
        os.path.join(rtl_dir, 'CIC'),
        os.path.join(rtl_dir, 'fft-core')
    ]

    PSS_LEN = 128
    parameters = {}
    parameters['IN_DW'] = IN_DW
    parameters['OUT_DW'] = OUT_DW
    parameters['TAP_DW'] = TAP_DW
    parameters['PSS_LEN'] = PSS_LEN
    parameters['ALGO'] = ALGO
    parameters['WINDOW_LEN'] = WINDOW_LEN

    # imaginary part is in upper 16 Bit
    PSS = np.zeros(PSS_LEN, 'complex')
    PSS[0:-1] = py3gpp.nrPSS(2)
    taps = np.fft.ifft(np.fft.fftshift(PSS))
    taps /= max(taps.real.max(), taps.imag.max())
    taps *= 2 ** (TAP_DW // 2 - 1)
    parameters['PSS_LOCAL'] = 0
    for i in range(len(taps)):
        parameters['PSS_LOCAL'] += ((int(np.round(np.imag(taps[i]))) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * i + TAP_DW // 2)) \
                                 + ((int(np.round(np.real(taps[i]))) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW * i))
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
    pass
