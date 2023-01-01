import numpy as np

class Model:
    def __init__(self, IN_DW, OUT_DW, PSS_LEN, PSS_LOCAL):
        print(f'model IN_DW = {IN_DW}')
        print(f'model OUT_DW = {OUT_DW}')
        print(f'model PSS_LEN = {PSS_LEN}')
        print(f'model PSS_LOCAL = {PSS_LOCAL}')
        pass

    def tick(self):
        pass

    def set_data(self, data_in):
        pass

    def reset(self):
        pass

    def get_data(self):
        pass