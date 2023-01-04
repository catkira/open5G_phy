import numpy as np

def _twos_comp(val, bits):
    """compute the 2's complement of int value val"""
    if (val & (1 << (bits - 1))) != 0:
        val = val - (1 << bits)
    return val            

class Model:
    def __init__(self, IN_DW, OUT_DW, PSS_LEN, PSS_LOCAL):
        # print(f'model IN_DW = {IN_DW}')
        # print(f'model OUT_DW = {OUT_DW}')
        # print(f'model PSS_LEN = {PSS_LEN}')
        # print(f'model PSS_LOCAL = {PSS_LOCAL}')
        taps = np.empty(PSS_LEN, 'complex')
        for i in range(PSS_LEN):
            taps[i] = _twos_comp(((PSS_LOCAL>>(32*i)) & 0xFFFF), 16) + 1j*_twos_comp(((PSS_LOCAL>>(32*i+16)) & 0xFFFF), 16)
        # for i in range(120):
        #     print(f'taps[{i}] = {taps[i]}')

    def tick(self):
        pass

    def set_data(self, data_in):
        pass

    def reset(self):
        pass

    def get_data(self):
        pass