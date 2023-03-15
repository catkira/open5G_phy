import numpy as np
import argparse
import sys
import os

def create_lut_file(NFFT, CP_LEN, CP_ADVANCE, path):
    FFT_OUT_DW = 32
    FFT_demod_taps = np.empty(2 ** NFFT, int)
    angle_step = 2 * np.pi * (CP_LEN - CP_ADVANCE) / (2 ** NFFT)
    for i in range(2 ** NFFT):
        FFT_demod_taps[i] = int((np.cos(angle_step * i + np.pi * (CP_LEN - CP_ADVANCE)) * (2 ** (FFT_OUT_DW // 2 - 1) - 1))) & (2 ** (FFT_OUT_DW // 2) - 1)
        tmp = int((np.sin(angle_step * i + np.pi * (CP_LEN - CP_ADVANCE)) * (2 ** (FFT_OUT_DW // 2 - 1) - 1))) & (2 ** (FFT_OUT_DW // 2) - 1)
        # print(f'{FFT_demod_taps[i]} = {np.cos(angle_step * i + np.pi * (CP_LEN - CP_ADVANCE))}')
        FFT_demod_taps[i] |= tmp << (FFT_OUT_DW // 2)
    filename = f'FFT_demod_taps_{int(NFFT)}_{int(CP_LEN)}_{int(CP_ADVANCE)}.hex'
    np.savetxt(os.path.join(path, filename), FFT_demod_taps.T, fmt = '%x', delimiter = ' ')

def main(args):
    print(sys.argv)

    parser = argparse.ArgumentParser(description='Creates lut table for DDS core')
    parser.add_argument('--path', metavar='path', required=False, default = '', help='path for lut file')
    parser.add_argument('--NFFT', metavar='NFFT', required=False, default = 8, help='NFFT (FFT length = 2 ** NFFT)')
    parser.add_argument('--CP_LEN', metavar='CP_LEN', required=False, default = 8, help='CP length in number of samples')
    parser.add_argument('--CP_ADVANCE', metavar='CP_ADVANCE', required=False, default = 8, help='CP advance in number of samples')
    args = parser.parse_args(args)

    create_lut_file(int(args.NFFT), int(args.CP_LEN), int(args.CP_ADVANCE), args.path)

if __name__ == "__main__":
    main(sys.argv[1:])