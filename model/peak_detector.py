import numpy as np


class Model:
    def __init__(self, IN_DW, WINDOW_LEN):
        self.IN_DW = int(IN_DW)
        self.WINDOW_LEN = int(WINDOW_LEN)

    def tick(self):
        pass

    def reset(self):
        pass