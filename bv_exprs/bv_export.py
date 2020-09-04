import os
import pyboolector
from pyboolector import Boolector, BoolectorException, BTOR_OPT_PRINT_DIMACS, BTOR_OPT_MODEL_GEN

import sys

try:
	full_bits = int(sys.argv[2])
except:
	full_bits = 3

def prove(x):
	btor.Assert(btor.Not(x))
	return btor.Sat()

half_bits = int(full_bits / 2)
BASE = 2 ** full_bits
HALF_BASE = int(2 ** half_bits)

btor = Boolector()

full_sort = btor.BitVecSort(full_bits)
half_sort = btor.BitVecSort(half_bits)

# btor.Set_opt(BTOR_OPT_MODEL_GEN, 1)
btor.Set_opt(BTOR_OPT_PRINT_DIMACS, 1)

x = btor.Var(full_sort, "x")
y = btor.Var(full_sort, "y")
z = btor.Var(full_sort, "z")

q = btor.Implies(
	x * z == y * z,
	x == y)

print(prove(q))
# print(x.assignment)
# print(y.assignment)
# print("{} {}".format(x.symbol, x.assignment))  # prints: x 00000100
# print("{} {}".format(y.symbol, y.assignment))  # prints: y 00010101