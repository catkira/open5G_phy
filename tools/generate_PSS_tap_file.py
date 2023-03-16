import numpy as np
import argparse
import sys
import os
import py3gpp

def create_tap_file(PSS_LEN, TAP_DW, N_id_2, path):
    PSS = np.zeros(PSS_LEN, 'complex')
    PSS[0:-1] = py3gpp.nrPSS(N_id_2)
    taps = np.fft.ifft(np.fft.fftshift(PSS))
    taps /= max(taps.real.max(), taps.imag.max())
    taps *= 2 ** (TAP_DW // 2 - 1) - 1

    PSS_taps = np.empty(PSS_LEN, int)
    for i in range(len(taps)):
        PSS_taps[i] = ((int(np.imag(taps[i])) & (2 ** (TAP_DW // 2) - 1)) << (TAP_DW // 2)) \
                                + (int(np.real(taps[i])) & (2 ** (TAP_DW // 2) - 1))
    filename = f'PSS_taps_{int(N_id_2)}.hex'
    np.savetxt(os.path.join(path, filename), PSS_taps.T, fmt = '%x', delimiter = ' ')

def main(args):
    print(sys.argv)

    parser = argparse.ArgumentParser(description='Creates lut table for DDS core')
    parser.add_argument('--path', metavar='path', required=False, default = '', help='path for lut file')
    parser.add_argument('--PSS_LEN', metavar='PSS_LEN', required=False, default = 8, help='Length of PSS in samples')
    parser.add_argument('--TAP_DW', metavar='TAP_DW', required=False, default = 8, help='TAP_DW')
    parser.add_argument('--N_id_2', metavar='N_id_2', required=False, default = 8, help='N_id_2')
    args = parser.parse_args(args)

    create_tap_file(int(args.PSS_LEN), int(args.TAP_DW), int(args.N_id_2), args.path)

if __name__ == '__main__':
    main(sys.argv[1:])